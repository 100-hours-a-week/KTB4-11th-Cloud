# syntax=docker/dockerfile:1
ARG APPLICATION_IMAGE
FROM alpine:3.22 AS agent
RUN apk add --no-cache curl
RUN curl --fail --location --retry 3 \
      https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.32.0/opentelemetry-javaagent.jar \
      --output /opentelemetry-javaagent.jar \
    && echo 'f787eb6c7f3d18e69a431e108a15278d25ee37f83d68b678f621e063f3988f82  /opentelemetry-javaagent.jar' | sha256sum -c -

FROM ${APPLICATION_IMAGE}
RUN test -f /app/application.jar
# Bind the agent to this image. A later ordinary CD image must not inherit a
# missing -javaagent jar through JAVA_TOOL_OPTIONS in its task definition.
COPY --from=agent --chmod=0444 /opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar
ENTRYPOINT ["java", "-javaagent:/opt/otel/opentelemetry-javaagent.jar", "-jar", "/app/application.jar"]
