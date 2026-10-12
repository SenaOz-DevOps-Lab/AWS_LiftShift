# vprofile - Docker ile Konteynerizasyon ve AWS Lift & Shift

Bu proje, Java tabanlı çok katmanlı bir web uygulaması olan **vprofile**'ı önce Docker konteynerlerine taşımayı, ardından tek bir AWS EC2 sunucusu üzerinde çalıştırmayı amaçlar. "Lift & Shift" yaklaşımında uygulamanın kodu değiştirilmeden, olduğu gibi yeni bir altyapıya (burada önce Docker, sonra bulut) taşınır.

Kaynak uygulama: [hkhcoder/vprofile-project](https://github.com/hkhcoder/vprofile-project)

---

## Proje Yol Haritası

| Aşama | Kapsam | Durum |
|---|---|---|
| 1a | Uygulamayı Docker ile konteynerize etmek ve yerelde çalıştırmak | Tamamlandı |
| 1b | Docker projesini tek bir EC2 sunucusuna taşıyıp elle deploy etmek | Sırada |
| 2 | S3 ile log/statik dosya depolama, CloudWatch ile metrik takibi | Planlandı |
| 3 | SSH + scp/tar ile tek komutla deploy scripti, snapshot/yedekleme stratejisi | Planlandı |

---

## Uygulama Mimarisi

vprofile beş ayrı servisten oluşur. Her servis kendi konteynerinde çalışır ve hepsi Docker Compose'un oluşturduğu ortak bir iç ağ üzerinden birbirleriyle **isim üzerinden** haberleşir.

```
Kullanıcı (tarayıcı)
        |
        | port 80
        v
+----------------+        +-------------------+
|  vproweb       | -----> |  vproapp          |
|  Nginx         |  8080  |  Tomcat 10 + .war |
|  (reverse      |        |  (Java 17,        |
|   proxy)       |        |   Spring 6)       |
+----------------+        +-------------------+
                             |      |       |
                    3306     |      | 11211 |  5672
                             v      v       v
                     +--------+ +---------+ +---------+
                     | vprodb | | vpro-   | | vpromq01|
                     | MySQL  | | cache01 | | RabbitMQ|
                     | 8.0.33 | |Memcached| |         |
                     +--------+ +---------+ +---------+
```

| Servis | İmaj | Görevi |
|---|---|---|
| `vproweb` | nginx (özel imaj) | Dış dünyaya açılan tek kapı. Gelen istekleri uygulamaya yönlendirir. |
| `vproapp` | tomcat:10-jdk17 (özel imaj) | Java uygulamasını (`ROOT.war`) çalıştırır. |
| `vprodb` | mysql:8.0.33 (özel imaj) | Kullanıcı bilgilerinin tutulduğu `accounts` veritabanı. |
| `vprocache01` | memcached | Veritabanı sorgularını önbelleğe alarak hızlandırır. |
| `vpromq01` | rabbitmq | Mesaj kuyruğu servisi. |

Dışarıya yalnızca Nginx'in 80 portu açıktır. Uygulama, veritabanı, önbellek ve kuyruk servisleri sadece iç ağdan erişilebilir. Bu, güvenlik açısından bilinçli bir tercihtir.

---

## Bu Aşamada Yapılanlar (Aşama 1a)

### 1. Kaynak kodun alınması

vprofile uygulamasının kaynak kodu (`src/`, `pom.xml`) hkhcoder/vprofile-project deposundan alındı. Uygulama Spring 6 ve Jakarta EE kullanan, Maven ile derlenen bir Java 17 projesidir. Derlendiğinde `vprofile-v2.war` dosyası üretir.

### 2. Uygulama ayarlarının konteyner ortamına uyarlanması

`src/main/resources/application.properties` dosyasında, uygulamanın bağlandığı servislerin adresleri Docker Compose servis adlarıyla aynı olacak şekilde düzenlendi:

```properties
jdbc.url=jdbc:mysql://vprodb:3306/accounts?...
jdbc.username=root
jdbc.password=vprodbpass

memcached.active.host=vprocache01
rabbitmq.address=vpromq01
```

**Neden önemli:** Docker Compose, aynı dosyada tanımlanan servisleri ortak bir ağa bağlar ve her servisin adını bir DNS kaydı gibi çözer. Uygulama `vprodb` adresine bağlanmak istediğinde Docker bu ismi otomatik olarak MySQL konteynerinin IP adresine çevirir. Bu sayede IP adresi yazmaya gerek kalmaz. Konteyner yeniden oluşturulup IP değişse bile bağlantı bozulmaz.

### 3. Dockerfile'ların yazılması

Her özel servis için `Docker-files/` altında ayrı bir klasör ve Dockerfile oluşturuldu.

**`Docker-files/app/Dockerfile` - Uygulama (multi-stage build)**

```dockerfile
FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -q package -DskipTests

FROM tomcat:10-jdk17
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=build /src/target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war
EXPOSE 8080
CMD ["catalina.sh", "run"]
```

- **Birinci aşama (build):** Maven imajı içinde kaynak kod derlenir ve `.war` dosyası üretilir. Bilgisayarda Maven veya JDK kurulu olmasına gerek kalmaz.
- **İkinci aşama:** Sadece Tomcat imajı alınır ve derlenmiş `.war` dosyası içine kopyalanır. Maven, kaynak kod ve derleme artıkları son imaja girmez. Böylece imaj hem küçülür hem de daha güvenli olur.
- `.war` dosyası `ROOT.war` olarak kopyalandığı için uygulama `/vprofile-v2` gibi bir alt yolda değil, doğrudan kök adreste (`/`) açılır.
- **Neden Tomcat 10:** Kod `jakarta.*` paketlerini kullanıyor. Tomcat 9 ve öncesi eski `javax.*` paketlerini desteklediği için bu uygulamayı çalıştıramaz.

**`Docker-files/db/Dockerfile` - Veritabanı**

```dockerfile
FROM mysql:8.0.33
ENV MYSQL_DATABASE="accounts"
COPY db_backup.sql /docker-entrypoint-initdb.d/db_backup.sql
```

- `MYSQL_DATABASE` ile konteyner ilk açıldığında `accounts` veritabanı otomatik oluşturulur.
- Resmi MySQL imajı, `/docker-entrypoint-initdb.d/` klasörüne konan `.sql` dosyalarını **ilk açılışta** otomatik çalıştırır. Bu sayede tablolar ve örnek kullanıcı (`admin_vp`) elle müdahale olmadan yüklenir.
- Not: Bu betik yalnızca veri klasörü boşken çalışır. Volume'da veri varsa tekrar çalışmaz.

**`Docker-files/web/Dockerfile` ve `nginvproapp.conf` - Nginx**

```dockerfile
FROM nginx
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginvproapp.conf /etc/nginx/conf.d/vproapp.conf
```

```nginx
upstream vproapp {
  server vproapp:8080;
}
server {
  listen 80;
  location / {
    proxy_pass http://vproapp;
  }
}
```

- Nginx'in varsayılan karşılama sayfası silinip yerine özel yapılandırma kondu.
- Nginx **reverse proxy** olarak çalışır: kullanıcıdan 80 portundan gelen isteği, iç ağdaki `vproapp` konteynerinin 8080 portuna iletir. Kullanıcı Tomcat ile doğrudan konuşmaz.

### 4. Docker Compose ile servislerin bir araya getirilmesi

`docker-compose.yml` dosyası beş servisi tek bir yapılandırmada toplar:

```yaml
services:
  vprodb:
    build: ./Docker-files/db
    environment:
      - MYSQL_ROOT_PASSWORD=vprodbpass
    volumes:
      - vprodbdata:/var/lib/mysql
    restart: always

  vprocache01:
    image: memcached
    restart: always

  vpromq01:
    image: rabbitmq
    environment:
      - RABBITMQ_DEFAULT_USER=guest
      - RABBITMQ_DEFAULT_PASS=guest
    restart: always

  vproapp:
    build:
      context: .
      dockerfile: Docker-files/app/Dockerfile
    depends_on:
      - vprodb
      - vprocache01
      - vpromq01
    restart: always

  vproweb:
    build: ./Docker-files/web
    ports:
      - "80:80"
    depends_on:
      - vproapp
    restart: always

volumes:
  vprodbdata: {}
```

Önemli kararlar:

- **`vprodbdata` volume'u:** MySQL verisi konteynerin dışında, Docker'ın yönettiği kalıcı bir alanda saklanır. Konteyner silinse ya da yeniden oluşturulsa bile veriler kaybolmaz.
- **`vproapp` için `context: .`:** Uygulama imajı derlenirken `pom.xml` ve `src/` klasörüne erişmesi gerektiği için build bağlamı proje kök dizini olarak verildi. Dockerfile ise ayrıca belirtildi.
- **`depends_on`:** Servislerin başlama sırasını belirler (önce veritabanı, önbellek ve kuyruk, sonra uygulama, en son Nginx).
- **`restart: always`:** `depends_on` yalnızca başlama sırasını garanti eder, servisin hazır olmasını beklemez. MySQL geç açılırsa uygulama ilk denemede bağlanamayıp kapanabilir. `restart: always` sayesinde otomatik olarak yeniden başlar ve veritabanı hazır olduğunda bağlanır.
- **Sadece `vproweb` için port yayınlandı:** Diğer servisler dışarıya kapalıdır.

### 5. Yerelde derleme ve test

Docker Desktop üzerinde, proje dizininde aşağıdaki komutlarla imajlar derlendi ve tüm sistem ayağa kaldırıldı:

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f vproapp
```

Bu işlem sonucunda üç özel imaj (`vproapp`, `vproweb`, `vprodb`) oluşturuldu, `memcached` ve `rabbitmq` hazır imajları Docker Hub'dan indirildi ve veritabanı için kalıcı volume oluşturuldu.

Uygulamaya `http://localhost` adresinden erişilir. Giriş bilgileri:

| Kullanıcı adı | Şifre |
|---|---|
| admin_vp | admin_vp |

Sistemi durdurmak için:

```bash
docker compose down        # konteynerleri kaldırır, veri volume'u korunur
docker compose down -v     # veri volume'unu da siler (veritabanı sıfırlanır)
```

### 6. Sürüm kontrolü

Proje bağımsız bir git deposu olarak başlatıldı ve GitHub'a gönderildi. Derleme çıktısı olan `target/` klasörü `.gitignore` ile depo dışında tutuldu.

---

## Klasör Yapısı

```
.
├── Docker-files/
│   ├── app/Dockerfile          # Maven ile derleme + Tomcat 10
│   ├── db/Dockerfile           # MySQL 8 + başlangıç verisi
│   ├── db/db_backup.sql        # accounts veritabanı dökümü
│   ├── web/Dockerfile          # Nginx
│   └── web/nginvproapp.conf    # Reverse proxy yapılandırması
├── docker-compose.yml          # 5 servisin tanımı
├── src/                        # Java kaynak kodu
├── pom.xml                     # Maven yapılandırması
├── ansible/                    # Kaynak depodan gelen Ansible dosyaları (bu aşamada kullanılmadı)
├── vagrant/                    # Kaynak depodan gelen Vagrant dosyaları (bu aşamada kullanılmadı)
└── Jenkinsfile                 # Kaynak depodan gelen CI dosyası (bu aşamada kullanılmadı)
```

---

## Kullanılan Teknolojiler

- **Uygulama:** Java 17, Spring MVC 6, Spring Security, Spring Data JPA, Hibernate, JSP
- **Derleme:** Maven 3.9
- **Sunucular:** Apache Tomcat 10, Nginx
- **Veri katmanı:** MySQL 8.0.33, Memcached, RabbitMQ
- **Konteynerizasyon:** Docker, Docker Compose, multi-stage build
- **Araçlar:** Docker Desktop, Git Bash, VS Code, Git, GitHub

---

## Sıradaki Adımlar

1. **EC2'ye taşıma (Aşama 1b):** Ubuntu 24.04 EC2 sunucusu, güvenlik grubu (SSH yalnızca kendi IP'mden, HTTP herkese açık), Elastic IP, Docker kurulumu ve `docker compose up` ile elle deploy.
2. **S3 ve CloudWatch (Aşama 2):** IAM Role ile EC2'nin S3'e erişimi, logların S3'e aktarılması, CloudWatch Agent ile bellek/disk metrikleri ve CPU alarmı.
3. **Otomasyon ve yedekleme (Aşama 3):** Tek komutla deploy scripti, MySQL dökümlerinin S3'e yedeklenmesi, EBS snapshot politikası ve geri yükleme testi.

---

## Notlar

- `application.properties` ve `docker-compose.yml` içindeki şifreler kaynak projenin varsayılan, eğitim amaçlı değerleridir. Gerçek bir ortamda bu değerler `.env` dosyası veya AWS Secrets Manager gibi bir gizli bilgi yöneticisi ile dışarıdan verilmelidir.
- Elasticsearch servisi bu kurulumda yer almaz. `application.properties` içinde `localhost` olarak bırakıldığı için uygulamanın arama ile ilgili kısmı bu ortamda çalışmaz.
