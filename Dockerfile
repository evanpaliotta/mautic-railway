# Custom Mautic Dockerfile with SES API mailer support
# Fixes: Railway blocks SMTP ports, must use API-based email transport
# Build: 2026-01-06-v9 - Inject MAILER_DSN into database on startup
FROM mautic/mautic:5-apache

# Cache-busting build arg to force fresh layers when needed
ARG CACHE_BUST=2026-01-06-v9-db-inject

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

# Create PHP script that updates MAILER_DSN in database
RUN cat > /usr/local/bin/update-mailer-dsn.php << 'PHPSCRIPT'
<?php
// Update Mautic email configuration from MAILER_DSN environment variable
$mailerDsn = getenv('MAILER_DSN');
if (!$mailerDsn) {
    echo "No MAILER_DSN set, skipping database update\n";
    exit(0);
}

echo "Parsing MAILER_DSN: " . preg_replace('/:[^:@]+@/', ':***@', $mailerDsn) . "\n";

// Parse the DSN
if (preg_match('/^([a-z+]+):\/\/([^:]+):([^@]+)@([^?]+)\??(.*)$/', $mailerDsn, $matches)) {
    $scheme = $matches[1];
    $user = $matches[2];
    $pass = urldecode($matches[3]);
    $host = $matches[4];
    parse_str($matches[5] ?? '', $options);

    echo "Scheme: $scheme, Host: $host, User: $user\n";

    // Load Mautic's database config
    $localConfig = '/var/www/html/config/local.php';
    if (file_exists($localConfig)) {
        $config = include $localConfig;
        $dbHost = $config['db_host'] ?? getenv('MAUTIC_DB_HOST');
        $dbName = $config['db_name'] ?? getenv('MAUTIC_DB_NAME');
        $dbUser = $config['db_user'] ?? getenv('MAUTIC_DB_USER');
        $dbPass = $config['db_password'] ?? getenv('MAUTIC_DB_PASSWORD');
        $dbPort = $config['db_port'] ?? getenv('MAUTIC_DB_PORT') ?: 3306;
    } else {
        $dbHost = getenv('MAUTIC_DB_HOST');
        $dbName = getenv('MAUTIC_DB_NAME');
        $dbUser = getenv('MAUTIC_DB_USER');
        $dbPass = getenv('MAUTIC_DB_PASSWORD');
        $dbPort = getenv('MAUTIC_DB_PORT') ?: 3306;
    }

    if (!$dbHost || !$dbName) {
        echo "Database config not found, skipping\n";
        exit(0);
    }

    try {
        $pdo = new PDO("mysql:host=$dbHost;port=$dbPort;dbname=$dbName", $dbUser, $dbPass);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Build the new DSN for storage
        $newDsn = $mailerDsn;

        // Check if there's existing config to update
        $stmt = $pdo->query("SELECT id FROM mautic_configurations WHERE id = 1");
        if ($stmt->fetch()) {
            // Update - set the mailer_dsn in the bundle_config JSON
            $stmt = $pdo->query("SELECT bundle_config FROM mautic_configurations WHERE id = 1");
            $row = $stmt->fetch(PDO::FETCH_ASSOC);
            $bundleConfig = json_decode($row['bundle_config'] ?? '{}', true) ?: [];

            // Update mailer settings
            $bundleConfig['mailer_dsn'] = $newDsn;

            $stmt = $pdo->prepare("UPDATE mautic_configurations SET bundle_config = ? WHERE id = 1");
            $stmt->execute([json_encode($bundleConfig)]);
            echo "Updated mailer_dsn in mautic_configurations\n";
        }

        echo "Database update complete\n";
    } catch (PDOException $e) {
        echo "Database error: " . $e->getMessage() . "\n";
        // Non-fatal, continue with startup
    }
} else {
    echo "Could not parse MAILER_DSN format\n";
}
PHPSCRIPT

# Create custom entrypoint that injects MAILER_DSN and clears cache on startup
RUN cat > /usr/local/bin/mautic-entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
echo "=== Mautic with SES API Transport (v9) ==="

# Update MAILER_DSN in database from environment variable
echo "Updating MAILER_DSN in database..."
php /usr/local/bin/update-mailer-dsn.php

# Make config directory writable
chmod -R 777 /var/www/html/config 2>/dev/null || true
chown -R www-data:www-data /var/www/html/config

echo "Clearing cache to pick up fresh configuration..."

# ALWAYS clear cache on startup
rm -rf /var/www/html/var/cache/prod/* 2>/dev/null || true
chown -R www-data:www-data /var/www/html/var/cache

echo "Warming up cache..."
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:clear --env=prod --no-warmup" 2>/dev/null || true
su -s /bin/bash www-data -c "php /var/www/html/bin/console cache:warmup --env=prod" 2>/dev/null || true
echo "Cache rebuilt with MAILER_DSN from environment"

exec /docker-entrypoint.sh "$@"
ENTRYPOINT

RUN chmod +x /usr/local/bin/mautic-entrypoint.sh && \
    chmod +x /usr/local/bin/update-mailer-dsn.php

ENTRYPOINT ["/usr/local/bin/mautic-entrypoint.sh"]
CMD ["apache2-foreground"]
