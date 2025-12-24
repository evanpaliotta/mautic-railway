# Custom Mautic Dockerfile that fixes Apache MPM configuration
FROM mautic/mautic:5-apache

# Fix the Apache MPM configuration error
# Disable conflicting MPM modules and ensure only one is loaded
RUN a2dismod mpm_event 2>/dev/null || true && \
    a2dismod mpm_worker 2>/dev/null || true && \
    a2enmod mpm_prefork && \
    echo "Apache MPM fixed to use prefork only"

# Ensure PHP mod is enabled for prefork
RUN a2enmod php || a2enmod php8.1 || a2enmod php8.2 || echo "PHP module already enabled"

# Install API-based mailer bridges for email sending (bypasses Railway's SMTP port blocking)
# Using --no-scripts to avoid triggering Mautic's asset generation which fails as root
# Then regenerate autoloader to ensure new packages are discoverable
RUN cd /var/www/html && \
    composer require symfony/amazon-mailer symfony/sendgrid-mailer --no-interaction --no-scripts && \
    composer dump-autoload --optimize
