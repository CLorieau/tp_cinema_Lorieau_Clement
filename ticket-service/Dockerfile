# ── Étape 1 : build ─────────────────────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# pom.xml seul d'abord : la couche des dépendances reste en cache
COPY pom.xml .
RUN mvn -q -B dependency:go-offline

COPY src ./src
RUN mvn -q -B package -DskipTests

# ── Étape 2 : image finale (JRE seulement, non-root) ────────────────────────
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

RUN addgroup -S spring && adduser -S -u 10001 -G spring spring
USER spring

COPY --from=build /app/target/*.jar app.jar

# Port réel de ticket-service (application.yaml)
EXPOSE 8086

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
