# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v3 - Force fresh build with proper package discovery
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v3

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
# Using --no-scripts to avoid npm permission issues, but we handle autoloading properly
RUN echo "Installing symfony/amazon-mailer for ses+api:// transport..." && \
    composer require symfony/amazon-mailer symfony/sendgrid-mailer \
    --no-interaction \
    --no-scripts \
    --prefer-dist && \
    echo "Packages installed successfully"

# Regenerate autoloader - this is critical for package discovery
RUN composer dump-autoload --optimize --classmap-authoritative && \
    echo "Autoloader regenerated"

# Switch back to root for cache and permission management
USER root

# Clear ALL caches completely - both Mautic and Symfony
RUN rm -rf /var/www/html/var/cache/* && \
    rm -rf /var/www/html/var/logs/* && \
    rm -rf /var/www/html/var/tmp/* 2>/dev/null || true && \
    mkdir -p /var/www/html/var/cache /var/www/html/var/logs && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor && \
    echo "Caches cleared, permissions set"

# Create startup script that warms cache as www-data (critical for proper service discovery)
RUN echo '#!/bin/bash' > /usr/local/bin/mautic-start.sh && \
    echo 'set -e' >> /usr/local/bin/mautic-start.sh && \
    echo 'echo "Starting Mautic with SES API mailer support..."' >> /usr/local/bin/mautic-start.sh && \
    echo 'su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:warmup --env=prod" 2>/dev/null || echo "Cache warmup skipped"' >> /usr/local/bin/mautic-start.sh && \
    echo 'exec apache2-foreground' >> /usr/local/bin/mautic-start.sh && \
    chmod +x /usr/local/bin/mautic-start.sh

# Verify packages are installed (build-time check)
RUN php -r "require '/var/www/html/vendor/autoload.php'; echo 'Autoload OK\n'; \
    if (class_exists('Symfony\Component\Mailer\Bridge\Amazon\Transport\SesTransportFactory')) { \
        echo 'SES Transport Factory: FOUND\n'; \
    } else { \
        echo 'SES Transport Factory: NOT FOUND - this is a problem\n'; \
        exit 1; \
    }"

CMD ["/usr/local/bin/mautic-start.sh"]
