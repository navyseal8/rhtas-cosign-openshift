# Multistage build using Red Hat UBI OpenJDK images from the Ecosystem Catalog:
#   https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21
#   https://catalog.redhat.com/en/software/containers/ubi9/openjdk-21-runtime
#
# Stage 1 (builder): JDK + Maven — compiles the Spring Boot app
# Stage 2 (runtime): JRE-only hardened runtime — no compiler/Maven (smaller attack surface)

ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/openjdk-21:1.21
ARG RUNTIME_IMAGE=registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21

# ---------- build ----------
FROM ${BUILDER_IMAGE} AS builder

USER root
WORKDIR /build

COPY pom.xml .
COPY src ./src

# Use the OpenShift-friendly Maven profile when available in the UBI image
RUN mvn -B -ntp -e -DskipTests package \
    && mv target/hello-world-*.jar /build/app.jar

# ---------- runtime ----------
FROM ${RUNTIME_IMAGE}

LABEL name="rhtas-hello-world" \
      summary="RHTAS cosign trust demo application" \
      description="Serves a static trust page with build version, signer identity, and Fulcio endpoint" \
      maintainer="rhtas-demo" \
      io.openshift.tags="rhtas,cosign,java,demo" \
      com.redhat.component="rhtas-hello-world"

ARG BUILD_VERSION=unknown
ARG IMAGE_DIGEST=unknown
ARG SIGNER_IDENTITY=unsigned
ARG SIGNED_AT=unknown
ARG SCENARIO=unknown
ARG FULCIO_URL=unknown
ARG REKOR_URL=unknown
ARG OIDC_ISSUER=unknown
ARG IMAGE_REF=unknown
ARG GIT_COMMIT=unknown
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/openjdk-21:1.21
ARG RUNTIME_IMAGE=registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21

ENV BUILD_VERSION=${BUILD_VERSION} \
    IMAGE_DIGEST=${IMAGE_DIGEST} \
    SIGNER_IDENTITY=${SIGNER_IDENTITY} \
    SIGNED_AT=${SIGNED_AT} \
    SCENARIO=${SCENARIO} \
    FULCIO_URL=${FULCIO_URL} \
    REKOR_URL=${REKOR_URL} \
    OIDC_ISSUER=${OIDC_ISSUER} \
    IMAGE_REF=${IMAGE_REF} \
    GIT_COMMIT=${GIT_COMMIT} \
    BUILDER_IMAGE=${BUILDER_IMAGE} \
    RUNTIME_IMAGE=${RUNTIME_IMAGE} \
    JAVA_APP_JAR=/deployments/app.jar

WORKDIR /deployments
COPY --from=builder --chown=185:0 /build/app.jar /deployments/app.jar

USER 185
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/deployments/app.jar"]
