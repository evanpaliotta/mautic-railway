# Custom Mautic Dockerfile that fixes Apache MPM configuration
FROM mautic/mautic:v5-apache

# Fix the Apache MPM configuration error
# Disable conflicting MPM modules and ensure only one is loaded
RUN a2dismod mpm_event 2>/dev/null || true && \
    a2dismod mpm_worker 2>/dev/null || true && \
    a2enmod mpm_prefork && \
    echo "Apache MPM fixed to use prefork only"

# Ensure PHP mod is enabled for prefork
RUN a2enmod php || a2enmod php8.1 || a2enmod php8.2 || echo "PHP module already enabled"

# Install Amazon SES mailer bridge for API-based email sending (bypasses SMTP port blocking)
RUN cd /var/www/html && composer require symfony/amazon-mailer --no-interaction
