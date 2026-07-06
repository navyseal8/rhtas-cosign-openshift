# syntax=docker/dockerfile:1
# Expects `mvn package` to have run in CI before `docker build`.
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.21

LABEL maintainer="rhtas-demo"

ARG BUILD_VERSION=unknown
ARG IMAGE_DIGEST=unknown
ARG SIGNER_IDENTITY=unsigned
ARG SIGNED_AT=unknown
ARG SCENARIO=unknown

ENV BUILD_VERSION=${BUILD_VERSION}
ENV IMAGE_DIGEST=${IMAGE_DIGEST}
ENV SIGNER_IDENTITY=${SIGNER_IDENTITY}
ENV SIGNED_AT=${SIGNED_AT}
ENV SCENARIO=${SCENARIO}

WORKDIR /app
COPY target/hello-world-*.jar /app/app.jar

USER 185
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
