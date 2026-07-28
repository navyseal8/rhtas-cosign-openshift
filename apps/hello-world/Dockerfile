# Multistage build on Red Hat hardened images (images.redhat.com — "hi" namespace).
# Catalog: https://images.redhat.com/
#
# Build stage  → registry.access.redhat.com/hi/openjdk:21.0.11-builder  (JDK + Maven)
# Runtime stage → registry.access.redhat.com/hi/openjdk:21.0.11-runtime (minimal runtime)
# Prefer numbered tags over :latest / :latest-runtime for reproducible builds.

# Build stage
FROM registry.access.redhat.com/hi/openjdk:21.0.11-builder AS builder
USER root
WORKDIR /app
COPY . .
RUN microdnf install -y mvn && microdnf clean all
# Spring Boot app: compile and package with Maven (not plain javac)
RUN mvn -B -ntp -e -DskipTests package \
    && cp target/hello-world-*.jar /app/app.jar

# Runtime stage
FROM registry.access.redhat.com/hi/openjdk:21.0.11-runtime

LABEL name="rhtas-hello-world" \
      summary="RHTAS cosign trust demo application" \
      description="Serves a trust page with build version, signer identity, and Fulcio endpoint" \
      maintainer="rhtas-demo" \
      io.openshift.tags="rhtas,cosign,java,hardened,demo" \
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
ARG BUILDER_IMAGE=registry.access.redhat.com/hi/openjdk:21.0.11-builder
ARG RUNTIME_IMAGE=registry.access.redhat.com/hi/openjdk:21.0.11-runtime

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
    RUNTIME_IMAGE=${RUNTIME_IMAGE}

WORKDIR /app
COPY --from=builder /app/app.jar /app/app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
