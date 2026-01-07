# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v4 - Register SES transport factory as Symfony service
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v4

# Fix the Apache MPM configuration error
RUN a2dismod mpm_event 2>/dev/null || true && \
    a2dismod mpm_worker 2>/dev/null || true && \
    a2enmod mpm_prefork && \
    echo "Apache MPM fixed to use prefork only"

# Ensure PHP mod is enabled for prefork
RUN a2enmod php || a2enmod php8.1 || a2enmod php8.2 || echo "PHP module already enabled"

# Create composer cache directory for www-data user
RUN mkdir -p /var/www/.composer/cache && \
    chown -R www-data:www-data /var/www/.composer

# Install API-based mailer bridges as www-data user
USER www-data
WORKDIR /var/www/html
ENV COMPOSER_HOME=/var/www/.composer

# Install the Amazon SES mailer bridge
RUN echo "Installing symfony/amazon-mailer for ses+api:// transport..." && \
    composer require symfony/amazon-mailer symfony/sendgrid-mailer \
    --no-interaction \
    --no-scripts \
    --prefer-dist && \
    echo "Packages installed successfully"

# Regenerate autoloader
RUN composer dump-autoload --optimize --classmap-authoritative && \
    echo "Autoloader regenerated"

# Switch back to root
USER root

# Register the SES transport factory as a Symfony service
# This is required because --no-scripts skips the Symfony Flex recipe
RUN mkdir -p /var/www/html/config/packages && \
    echo 'services:' > /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '    Symfony\Component\Mailer\Bridge\Amazon\Transport\SesTransportFactory:' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '        tags:' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '            - { name: mailer.transport_factory }' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo "" >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '    Symfony\Component\Mailer\Bridge\Sendgrid\Transport\SendgridTransportFactory:' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '        tags:' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    echo '            - { name: mailer.transport_factory }' >> /var/www/html/config/packages/amazon_mailer.yaml && \
    chown www-data:www-data /var/www/html/config/packages/amazon_mailer.yaml && \
    echo "SES and SendGrid transport factories registered"

# Clear ALL caches completely
RUN rm -rf /var/www/html/var/cache/* && \
    rm -rf /var/www/html/var/logs/* && \
    rm -rf /var/www/html/var/tmp/* 2>/dev/null || true && \
    mkdir -p /var/www/html/var/cache /var/www/html/var/logs && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor && \
    echo "Caches cleared, permissions set"

# Create custom entrypoint that clears cache before starting
# This ensures the new transport factories are discovered at runtime
RUN echo '#!/bin/bash' > /usr/local/bin/mautic-entrypoint.sh && \
    echo 'echo "=== Mautic with SES API Transport ===" ' >> /usr/local/bin/mautic-entrypoint.sh && \
    echo 'rm -rf /var/www/html/var/cache/prod/* 2>/dev/null || true' >> /usr/local/bin/mautic-entrypoint.sh && \
    echo 'chown -R www-data:www-data /var/www/html/var/cache 2>/dev/null || true' >> /usr/local/bin/mautic-entrypoint.sh && \
    echo 'exec /docker-entrypoint.sh "$@"' >> /usr/local/bin/mautic-entrypoint.sh && \
    chmod +x /usr/local/bin/mautic-entrypoint.sh

# Verify packages are installed (build-time check)
RUN php -r 'require "/var/www/html/vendor/autoload.php"; \
    $found = class_exists("Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory"); \
    echo $found ? "SES Transport Factory: FOUND\n" : "SES Transport Factory: NOT FOUND\n"; \
    exit($found ? 0 : 1);'

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
