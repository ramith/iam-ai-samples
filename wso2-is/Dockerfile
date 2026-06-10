# WSO2 Identity Server image for the srt-emp demo.
#
# Based on the official wso2/wso2is image pulled from Docker Hub — no local IS
# zip pack required. The image already ships the extracted server tree at
# ${WSO2_SERVER_HOME} (/home/wso2carbon/wso2is-<version>). We layer on top:
#   - runtime tooling the entrypoint/bootstrap need (curl, jq, bash)
#   - the UAEPass federated authenticator connector + branded assets
#   - a /opt/wso2is symlink so the entrypoint, bootstrap script and the
#     compose data volume keep referencing the historical /opt/wso2is path
#
# Build context is ./wso2-is (see docker-compose.yml), so COPY paths are
# relative to that folder. Layout within the context:
#   uaepass/     — UAEPass connector JAR, error JSP, logo
#   entrypoint/  — container entrypoint script
#
# WSO2 IS version. Must be 7.3.0 or newer. The matching tag must exist on
# Docker Hub (https://hub.docker.com/r/wso2/wso2is/tags). To use a newer
# version, change ONLY this value — nothing else below.
ARG WSO2IS_VERSION=7.3.0

FROM wso2/wso2is:${WSO2IS_VERSION}-alpine

# Re-declare after FROM so it is in scope for the build stage below.
ARG WSO2IS_VERSION
ENV WSO2_SERVER_HOME=/home/wso2carbon/wso2is-${WSO2IS_VERSION}

# Root is needed to install packages and write into the server tree.
USER root

# Runtime deps: curl (entrypoint readiness probe), jq (bootstrap JSON parsing),
# bash (entrypoint uses `set -euo pipefail`). Alpine base → apk.
RUN apk add --no-cache curl jq bash

# ── UAEPass federated authenticator connector ──────────────────────────────
# Deploy the UAEPass OIDC authenticator into dropins so IS loads it at boot,
# the branded error page into the authentication endpoint, and the UAEPass
# logo into both the login-UI theme and the Console connection-logo dirs.
COPY uaepass/org.wso2.carbon.identity.authenticator.uaepass-1.1.6.jar \
     ${WSO2_SERVER_HOME}/repository/components/dropins/
COPY uaepass/uaePassError.jsp \
     ${WSO2_SERVER_HOME}/repository/deployment/server/webapps/authenticationendpoint/uaePassError.jsp
COPY uaepass/uaepass-logo.png \
     ${WSO2_SERVER_HOME}/repository/deployment/server/webapps/authenticationendpoint/libs/themes/default/assets/images/identity-providers/uaepass-logo.png
COPY uaepass/uaepass-logo.png \
     ${WSO2_SERVER_HOME}/repository/deployment/server/webapps/console/resources/connections/assets/images/logos/uaepass-logo.png

# Default (non-UAEPass) login-page logo, served by URL and referenced by the
# generic branding when ENABLE_UAEPASS=false.
COPY default/smart-employee-logo.jpeg \
     ${WSO2_SERVER_HOME}/repository/deployment/server/webapps/authenticationendpoint/libs/themes/default/assets/images/smart-employee-logo.jpeg

# Back-compat symlink: entrypoint, bootstrap and the compose volume all use
# /opt/wso2is. Point it at the version-specific server home.
RUN ln -s ${WSO2_SERVER_HOME} /opt/wso2is

COPY entrypoint/custom-entrypoint.sh /opt/custom-entrypoint.sh
RUN chmod +x /opt/custom-entrypoint.sh \
    && chown -R wso2carbon:wso2 ${WSO2_SERVER_HOME}

EXPOSE 9443 9763

USER wso2carbon

ENTRYPOINT ["/opt/custom-entrypoint.sh"]
