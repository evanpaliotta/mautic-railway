# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v14 - Clear cache at startup to use MAILER_DSN env var
FROM mautic/mautic:5-apache

# Cache-busting build arg
ARG CACHE_BUST=2026-01-06-v14-use-env-var

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

# Fix node_modules permissions BEFORE composer
RUN rm -rf /var/www/html/node_modules 2>/dev/null || true && \
    mkdir -p /var/www/html/node_modules && \
    chown -R www-data:www-data /var/www/html/node_modules

# Also ensure var directory is writable
RUN mkdir -p /var/www/html/var/cache /var/www/html/var/logs && \
    chown -R www-data:www-data /var/www/html/var

# Install API-based mailer bridges as www-data user
USER www-data
WORKDIR /var/www/html
ENV COMPOSER_HOME=/var/www/.composer
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV npm_config_cache=/tmp/.npm

# Install the Amazon SES mailer bridge
RUN echo "Installing symfony/amazon-mailer for ses+api:// transport..." && \
    composer require symfony/amazon-mailer symfony/sendgrid-mailer \
    --no-interaction \
    --prefer-dist 2>&1 || { \
        echo "Composer with scripts failed, trying without scripts..."; \
        composer require symfony/amazon-mailer symfony/sendgrid-mailer \
        --no-interaction \
        --no-scripts \
        --prefer-dist; \
    } && \
    echo "Packages installed successfully"

# Regenerate autoloader
RUN composer dump-autoload --optimize --classmap-authoritative && \
    echo "Autoloader regenerated"

# Switch back to root for config changes
USER root

# Create the mailer transport config
RUN mkdir -p /var/www/html/config/packages && \
    cat > /var/www/html/config/packages/mailer_transports.yaml << 'YAMLCONFIG'
# Custom mailer transport factories for AWS SES API
services:
    _defaults:
        autowire: true
        autoconfigure: true

    Symfony\Component\Mailer\Bridge\Amazon\Transport\SesTransportFactory:
        tags:
            - { name: mailer.transport_factory }

    Symfony\Component\Mailer\Bridge\Sendgrid\Transport\SendgridTransportFactory:
        tags:
            - { name: mailer.transport_factory }
YAMLCONFIG

RUN chown www-data:www-data /var/www/html/config/packages/mailer_transports.yaml

# CRITICAL: Remove any hardcoded mailer_dsn from local.php
# This forces Mautic to use the MAILER_DSN environment variable
RUN if [ -f /var/www/html/config/local.php ]; then \
    echo "Removing mailer_dsn from local.php to use env var..." && \
    php -r " \
        \$config = include '/var/www/html/config/local.php'; \
        unset(\$config['mailer_dsn']); \
        file_put_contents('/var/www/html/config/local.php', '<?php return ' . var_export(\$config, true) . ';'); \
        echo 'Removed mailer_dsn from local.php\n'; \
    "; \
    fi && \
    chown www-data:www-data /var/www/html/config/local.php

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/config && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor

# Clear cache during build
USER www-data
RUN rm -rf /var/www/html/var/cache/* && \
    php /var/www/html/bin/console cache:clear --env=prod --no-warmup 2>&1 || echo "Cache clear done"

USER root

# Verify packages are installed
RUN php -r 'require "/var/www/html/vendor/autoload.php"; \
    $found = class_exists("Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory"); \
    echo $found ? "SES Transport Factory: FOUND\n" : "SES Transport Factory: NOT FOUND\n"; \
    exit($found ? 0 : 1);'

# Create custom entrypoint that clears cache on startup to pick up MAILER_DSN env var
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v14) ==="
echo "Using MAILER_DSN from environment variable"

# Show MAILER_DSN (masked) for debugging
if [ -n "$MAILER_DSN" ]; then
    echo "MAILER_DSN is set (value masked for security)"
    echo "DSN scheme: $(echo $MAILER_DSN | cut -d':' -f1)"
else
    echo "WARNING: MAILER_DSN is not set!"
fi

# CRITICAL: Clear all caches on startup to pick up environment variables
echo "Clearing caches to pick up environment variables..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
chown -R www-data:www-data /var/www/html/var/cache

# Warm up cache with current environment
echo "Warming up cache with current environment..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:warmup --env=prod" 2>/dev/null || true

# Check if SES transport is available
echo "Checking SES transport availability..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console debug:container --tag=mailer.transport_factory --env=prod 2>&1 | head -10" || echo "Could not check transports"

echo "Startup complete."
exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
