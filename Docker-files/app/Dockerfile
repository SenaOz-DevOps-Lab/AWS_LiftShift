# 1. aşama: Maven ile kodu derle, .war dosyası üret
FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -q package -DskipTests

# 2. aşama: Sadece .war dosyasını Tomcat'e koy
FROM tomcat:10-jdk17
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=build /src/target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war
EXPOSE 8080
CMD ["catalina.sh", "run"]
