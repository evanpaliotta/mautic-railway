# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-07-v17 - Fix build failure when local.php doesn't exist
FROM mautic/mautic:5-apache

# Cache-busting build arg
ARG CACHE_BUST=2026-01-06-v16-force-local-php

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
# Note: local.php may not exist during build - it gets created at runtime
RUN if [ -f /var/www/html/config/local.php ]; then \
    echo "Removing mailer_dsn from local.php to use env var..." && \
    php -r " \
        \$config = include '/var/www/html/config/local.php'; \
        unset(\$config['mailer_dsn']); \
        file_put_contents('/var/www/html/config/local.php', '<?php return ' . var_export(\$config, true) . ';'); \
        echo 'Removed mailer_dsn from local.php\n'; \
    " && \
    chown www-data:www-data /var/www/html/config/local.php; \
    fi

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

# Create custom entrypoint that FORCEFULLY updates local.php and clears ALL caches
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v16) ==="
echo "This version forcefully updates local.php and clears ALL caches"

LOCAL_PHP="/var/www/html/config/local.php"

# Show MAILER_DSN (masked) for debugging
if [ -n "$MAILER_DSN" ]; then
    echo "MAILER_DSN is set (value masked for security)"
    echo "DSN scheme: $(echo $MAILER_DSN | cut -d':' -f1)"
    echo "DSN contains FFHZFGN4: $(echo $MAILER_DSN | grep -c 'FFHZFGN4' || echo 0)"

    # STEP 1: Remove ALL cache directories
    echo "STEP 1: Removing ALL cache directories..."
    rm -rf /var/www/html/var/cache/* 2>/dev/null || true
    rm -rf /tmp/mautic* 2>/dev/null || true

    # STEP 2: Read current local.php and show what's there
    echo "STEP 2: Reading current local.php..."
    if [ -f "$LOCAL_PHP" ]; then
        echo "Current mailer_dsn in local.php:"
        php -r "\$c = include '$LOCAL_PHP'; echo isset(\$c['mailer_dsn']) ? 'Key: ' . substr(\$c['mailer_dsn'], 10, 20) . '...' : 'NOT SET'; echo \"\n\";"
    else
        echo "local.php does not exist!"
    fi

    # STEP 3: FORCE write MAILER_DSN to local.php
    echo "STEP 3: FORCE writing MAILER_DSN to local.php..."
    php -r "
        \$localPhpPath = '$LOCAL_PHP';
        \$mailerDsn = getenv('MAILER_DSN');

        // Read existing config or create new
        if (file_exists(\$localPhpPath)) {
            \$config = include \$localPhpPath;
            if (!is_array(\$config)) {
                \$config = [];
            }
        } else {
            \$config = [];
        }

        // FORCE set mailer_dsn
        \$config['mailer_dsn'] = \$mailerDsn;

        // Write back to file
        \$content = '<?php' . PHP_EOL . 'return ' . var_export(\$config, true) . ';' . PHP_EOL;
        file_put_contents(\$localPhpPath, \$content);

        echo 'Wrote mailer_dsn to local.php' . PHP_EOL;
        echo 'New DSN starts with: ' . substr(\$mailerDsn, 0, 30) . '...' . PHP_EOL;
        echo 'Contains FFHZFGN4: ' . (strpos(\$mailerDsn, 'FFHZFGN4') !== false ? 'YES' : 'NO') . PHP_EOL;
    "

    # STEP 4: Set ownership
    chown www-data:www-data "$LOCAL_PHP"
    chmod 644 "$LOCAL_PHP"

    # STEP 5: Verify the file was written correctly
    echo "STEP 5: Verifying local.php was updated..."
    php -r "
        \$c = include '$LOCAL_PHP';
        if (isset(\$c['mailer_dsn'])) {
            \$dsn = \$c['mailer_dsn'];
            echo 'Verified: DSN starts with: ' . substr(\$dsn, 0, 30) . '...' . PHP_EOL;
            echo 'Verified: Contains FFHZFGN4: ' . (strpos(\$dsn, 'FFHZFGN4') !== false ? 'YES' : 'NO') . PHP_EOL;
        } else {
            echo 'ERROR: mailer_dsn NOT FOUND in local.php!' . PHP_EOL;
        }
    "

    # STEP 6: Ensure cache directory exists with correct permissions
    echo "STEP 6: Setting up cache directory..."
    mkdir -p /var/www/html/var/cache
    chown -R www-data:www-data /var/www/html/var/cache
    chmod -R 775 /var/www/html/var/cache

    # STEP 7: Clear and warm cache as www-data
    echo "STEP 7: Clearing and warming cache..."
    su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod 2>&1" || echo "Cache clear completed with warnings"

    # STEP 8: Verify DSN is in cache
    echo "STEP 8: Checking cached configuration..."
    su -s /bin/bash www-data -c "php -r \"
        require '/var/www/html/vendor/autoload.php';
        \\\$config = include '/var/www/html/config/local.php';
        echo 'After cache clear, DSN contains FFHZFGN4: ' . (strpos(\\\$config['mailer_dsn'] ?? '', 'FFHZFGN4') !== false ? 'YES' : 'NO') . PHP_EOL;
    \"" || echo "Could not verify cached config"

else
    echo "WARNING: MAILER_DSN is not set! Email will not work."
fi

echo "=== Startup complete (v16) ==="
exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
