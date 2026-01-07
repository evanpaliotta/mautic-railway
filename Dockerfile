# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v12 - Hardcode correct MAILER_DSN in build
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v12-hardcode

# Build-time argument for MAILER_DSN (will be injected by Railway)
ARG MAILER_DSN_BUILD="ses+api://AKIATQN6XWF5FFHZFGN4:iGgjtUac0E6Q%2FLlh1jDKeu3iwBAmHEw8gyytjTEH@default?region=us-east-2"

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

# Fix node_modules permissions BEFORE composer (to avoid npm ci failures)
# This allows the Symfony Flex recipe to run without npm permission errors
RUN rm -rf /var/www/html/node_modules 2>/dev/null || true && \
    mkdir -p /var/www/html/node_modules && \
    chown -R www-data:www-data /var/www/html/node_modules

# Also ensure var directory is writable
RUN mkdir -p /var/www/html/var/cache /var/www/html/var/logs && \
    chown -R www-data:www-data /var/www/html/var

# Install API-based mailer bridges as www-data user
# Run WITHOUT --no-scripts so Symfony Flex recipe properly registers transport factories
USER www-data
WORKDIR /var/www/html
ENV COMPOSER_HOME=/var/www/.composer
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV npm_config_cache=/tmp/.npm

# Install the Amazon SES mailer bridge - let Flex recipe run
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

# Switch back to root for final steps
USER root

# If Flex recipe didn't run, manually create the service config
RUN if [ ! -f /var/www/html/config/packages/amazon_mailer.yaml ]; then \
    mkdir -p /var/www/html/config/packages && \
    printf '%s\n' \
        'services:' \
        '    Symfony\Component\Mailer\Bridge\Amazon\Transport\SesTransportFactory:' \
        '        tags:' \
        '            - { name: mailer.transport_factory }' \
        '' \
        '    Symfony\Component\Mailer\Bridge\Sendgrid\Transport\SendgridTransportFactory:' \
        '        tags:' \
        '            - { name: mailer.transport_factory }' \
        > /var/www/html/config/packages/amazon_mailer.yaml && \
    chown www-data:www-data /var/www/html/config/packages/amazon_mailer.yaml && \
    echo "Created amazon_mailer.yaml manually"; \
    fi

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/config && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor

# CRITICAL: Inject MAILER_DSN into local.php at BUILD TIME
# This ensures the correct credentials are baked into the image
ARG MAILER_DSN_BUILD
RUN echo "Injecting MAILER_DSN into local.php at build time..." && \
    if [ -f /var/www/html/config/local.php ]; then \
        php -r " \
            \$config = include '/var/www/html/config/local.php'; \
            \$config['mailer_dsn'] = '${MAILER_DSN_BUILD}'; \
            file_put_contents('/var/www/html/config/local.php', '<?php return ' . var_export(\$config, true) . ';'); \
            echo 'Updated local.php with new mailer_dsn\n'; \
        "; \
    else \
        echo '<?php return array(\"mailer_dsn\" => \"'${MAILER_DSN_BUILD}'\");' > /var/www/html/config/local.php; \
        echo 'Created new local.php with mailer_dsn'; \
    fi && \
    chown www-data:www-data /var/www/html/config/local.php && \
    cat /var/www/html/config/local.php | head -5

# Clear cache and rebuild container as www-data
USER www-data

# Force complete cache rebuild
RUN rm -rf /var/www/html/var/cache/* && \
    php /var/www/html/bin/console cache:clear --env=prod --no-warmup 2>&1 || echo "Cache clear completed" && \
    php /var/www/html/bin/console cache:warmup --env=prod 2>&1 || echo "Cache warmup completed"

# Switch back to root for final steps
USER root

# Verify packages are installed (build-time check)
RUN php -r 'require "/var/www/html/vendor/autoload.php"; \
    $found = class_exists("Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory"); \
    echo $found ? "SES Transport Factory: FOUND\n" : "SES Transport Factory: NOT FOUND\n"; \
    exit($found ? 0 : 1);'

# Check if transport is actually registered in container
RUN echo "Checking container for mailer transports..." && \
    php /var/www/html/bin/console debug:container --tag=mailer.transport_factory --env=prod 2>&1 | head -20 || echo "Could not check container"

# Create custom entrypoint that clears cache on startup
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v12) ==="
echo "MAILER_DSN is baked into image at build time"

# Clear all caches on startup to ensure fresh config
echo "Clearing caches..."
rm -rf /var/www/html/var/cache/* 2>/dev/null || true
chown -R www-data:www-data /var/www/html/var/cache

# Warm up cache
echo "Warming up cache..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:warmup --env=prod" 2>/dev/null || true

echo "Startup complete."
exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
