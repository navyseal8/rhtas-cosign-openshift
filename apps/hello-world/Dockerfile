# Multistage build:
# Build stage  → registry.access.redhat.com/ubi9/openjdk-21:1.21              (JDK + Maven)
# Runtime stage → registry.access.redhat.com/hi/openjdk:21.0.11-runtime (Hummingbird hardened)
# Prefer numbered tags over :latest for reproducible builds.

# Build stage
FROM registry.access.redhat.com/ubi9/openjdk-21:1.21 AS builder
WORKDIR /app
COPY . .
# Spring Boot app: compile and package with Maven (not plain javac)
RUN mvn -B -ntp -e -DskipTests package \
    && cp target/hello-world-*.jar /app/app.jar

# Runtime stage (Hummingbird / Red Hat Hardened Images)
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
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/openjdk-21:1.21
ARG RUNTIME_IMAGE=registry.access.redhat.com/hi/openjdk:21.0.11-runtime
ARG TUF_URL=unknown
ARG COSIGN_IMAGE=registry.redhat.io/rhtas/cosign-rhel9

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
    TUF_URL=${TUF_URL} \
    COSIGN_IMAGE=${COSIGN_IMAGE}

WORKDIR /app
COPY --from=builder /app/app.jar /app/app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
