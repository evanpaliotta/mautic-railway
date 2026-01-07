# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v13 - Fix transport factory registration
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v13-fix-transport

# Build-time argument for MAILER_DSN
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

# CRITICAL: Create the mailer transport config in the correct location
# Mautic uses Symfony's config loading, so we put it in config/packages/
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

RUN chown www-data:www-data /var/www/html/config/packages/mailer_transports.yaml && \
    echo "Created mailer_transports.yaml" && \
    cat /var/www/html/config/packages/mailer_transports.yaml

# Also add to services.yaml to ensure it's loaded
RUN if [ -f /var/www/html/config/services.yaml ]; then \
    echo "" >> /var/www/html/config/services.yaml && \
    echo "# AWS SES Transport Factory" >> /var/www/html/config/services.yaml && \
    echo "    Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory:" >> /var/www/html/config/services.yaml && \
    echo "        tags:" >> /var/www/html/config/services.yaml && \
    echo "            - { name: mailer.transport_factory }" >> /var/www/html/config/services.yaml && \
    echo "Added SES factory to services.yaml"; \
    fi

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html/config && \
    chown -R www-data:www-data /var/www/html/var && \
    chown -R www-data:www-data /var/www/html/vendor

# Inject MAILER_DSN into local.php at BUILD TIME
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
        echo '<?php return array("mailer_dsn" => "'${MAILER_DSN_BUILD}'");' > /var/www/html/config/local.php; \
        echo 'Created new local.php with mailer_dsn'; \
    fi && \
    chown www-data:www-data /var/www/html/config/local.php && \
    echo "=== local.php contents ===" && \
    cat /var/www/html/config/local.php

# Clear cache and rebuild container as www-data
USER www-data

# Force complete cache rebuild with transport factory
RUN rm -rf /var/www/html/var/cache/* && \
    echo "Cache cleared, rebuilding with transport factories..." && \
    php /var/www/html/bin/console cache:clear --env=prod --no-warmup 2>&1 || echo "Cache clear done" && \
    php /var/www/html/bin/console cache:warmup --env=prod 2>&1 || echo "Cache warmup done"

# Switch back to root for verification
USER root

# Verify packages are installed (build-time check)
RUN php -r 'require "/var/www/html/vendor/autoload.php"; \
    $found = class_exists("Symfony\\Component\\Mailer\\Bridge\\Amazon\\Transport\\SesTransportFactory"); \
    echo $found ? "SES Transport Factory: FOUND\n" : "SES Transport Factory: NOT FOUND\n"; \
    exit($found ? 0 : 1);'

# Check if transport is registered in container
RUN echo "=== Checking container for mailer transports ===" && \
    php /var/www/html/bin/console debug:container --tag=mailer.transport_factory --env=prod 2>&1 || echo "Container check completed"

# List all available mailer transports
RUN echo "=== Listing all transports ===" && \
    php /var/www/html/bin/console debug:container mailer --env=prod 2>&1 | head -30 || echo "Mailer services listed"

# Create custom entrypoint - DO NOT clear cache (preserve build-time cache)
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v13) ==="
echo "Transport factories registered at build time"
echo "NOT clearing cache to preserve transport registration"

# Only ensure cache directory is writable, don't clear it
chown -R www-data:www-data /var/www/html/var/cache 2>/dev/null || true

# Debug: Check if SES transport is available
echo "Checking SES transport availability..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console debug:container --tag=mailer.transport_factory --env=prod 2>&1 | head -10" || echo "Could not check transports"

echo "Startup complete."
exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
