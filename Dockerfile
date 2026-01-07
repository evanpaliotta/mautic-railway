# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v5 - Force proper Symfony cache rebuild with transport factories
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v5

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

# Switch back to root for config changes
USER root

# Register the SES transport factory as a Symfony service
# This is required because --no-scripts skips the Symfony Flex recipe
# Create config in both possible locations Mautic might check
RUN mkdir -p /var/www/html/config/packages && \
    cat > /var/www/html/config/packages/amazon_mailer.yaml << 'EOF'
services:
    Symfony\Component\Mailer\Bridge\Amazon\Transport\SesTransportFactory:
        tags:
            - { name: mailer.transport_factory }

    Symfony\Component\Mailer\Bridge\Sendgrid\Transport\SendgridTransportFactory:
        tags:
            - { name: mailer.transport_factory }
EOF

# Also create in app/config for older Mautic config loading
RUN mkdir -p /var/www/html/app/config && \
    cp /var/www/html/config/packages/amazon_mailer.yaml /var/www/html/app/config/amazon_mailer.yaml

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/config && \
    chown -R www-data:www-data /var/www/html/app/config && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor

# Clear cache and rebuild container as www-data
USER www-data

# Force complete cache rebuild - this is critical for Symfony to discover the new services
RUN rm -rf /var/www/html/var/cache/* && \
    php /var/www/html/bin/console cache:clear --env=prod --no-warmup 2>/dev/null || true && \
    php /var/www/html/bin/console cache:warmup --env=prod 2>/dev/null || echo "Cache warmup completed (or skipped)"

# Switch back to root for final steps
USER root

# Verify packages are installed (build-time check)
RUN php -r 'require "/var/www/html/vendor/autoload.php"; \
    $found = class_exists("Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory"); \
    echo $found ? "SES Transport Factory: FOUND\n" : "SES Transport Factory: NOT FOUND\n"; \
    exit($found ? 0 : 1);'

# Create custom entrypoint that ensures cache is fresh at runtime
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v5) ==="

# Check if cache needs rebuilding (first boot or volume mount)
if [ ! -f /var/www/html/var/cache/prod/container.php ] && [ ! -f /var/www/html/var/cache/prod/App_KernelProdContainer.php ]; then
    echo "Cache not found, warming up..."
    rm -rf /var/www/html/var/cache/prod/* 2>/dev/null || true
    chown -R www-data:www-data /var/www/html/var/cache
    su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:warmup --env=prod" 2>/dev/null || true
    echo "Cache warmed up"
fi

exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
