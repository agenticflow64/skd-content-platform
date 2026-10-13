# SKD — платформа агрегации контента и персональной ленты

Пет-проект: платформа собирает посты из внешних источников (Telegram-каналы, веб-фиды), находит почти-дубликаты на эмбеддингах, обогащает контент NLP-признаками, строит профили интересов пользователя и отдаёт персональную ленту во Flutter-клиент. Пять независимых подсистем в одном монорепо: контент-пайплайн на Kotlin, два Python-сервиса с ML, платформа из шести микросервисов и мобильный клиент. Общая плоскость данных одна: PostgreSQL 17 с pgvector, Kafka, Valkey, SeaweedFS.

## Архитектура

```mermaid
flowchart TB
    subgraph Client["Frontend Client"]
        FE["frontend-app<br/>(Flutter — Android + Web)"]
    end

    subgraph Backend["Backend Platform (Kotlin / Spring Boot)"]
        GW["api-gateway :8080<br/>WebFlux · JWT · rate limit · HMAC"]
        AUTH["auth-service :8081<br/>registration · JWT · SMTP"]
        USER["user-service :8082<br/>profiles · onboarding"]
        UI["user-interactions-service :8083<br/>event batching"]
        SUB["subscription-service :8084<br/>YooKassa payments"]
        FEED["feed-service :8085<br/>feed assembly · cache"]
    end

    subgraph ML["ML / Content Pipeline"]
        CFG["config-service :8081"]
        PARSER["content-parser-service :8082"]
        AGG["content-aggregator-service :8086"]
        DEDUP["dedup-worker<br/>(GPU · polls raw_content)"]
        REC["rec-system :8000<br/>FastAPI + APScheduler"]
    end

    subgraph Data["Shared Data Plane"]
        PG[("PostgreSQL 17<br/>+ pgvector<br/>content_agg_db")]
        VK[("Valkey 8")]
        KAFKA{{"Kafka 7.9 (KRaft)<br/>6 topics · JSON"}}
        S3[("SeaweedFS<br/>S3 media")]
    end

    FE -->|HTTPS · JWT Bearer| GW
    GW --> AUTH & USER & UI & SUB & FEED

    FEED -->|POST /recommendations| REC
    FEED -->|GET content objects| AGG
    USER -->|onboarding · categories| REC
    UI -->|user.interactions.batch| KAFKA --> REC

    CFG -->|source.config.updated| KAFKA --> PARSER
    PARSER -->|INSERT raw_content| PG
    DEDUP -->|poll · UPDATE is_processed_by_dedup| PG
    REC -->|poll · NLP · UPDATE is_processed_by_rec| PG
    AGG -->|READ published_content| PG

    AUTH & USER & UI & SUB & FEED --- PG
    GW & FEED --- VK
    PARSER & AGG --- S3
    AUTH -->|user.registered| KAFKA
    USER -->|user.created| KAFKA
    SUB -->|subscription.changed| KAFKA
    REC -->|recommendations.updated| KAFKA --> FEED
```

Ключевые правила, которые держат систему целой: клиент ходит только в шлюз, каждый сервис пишет только в свои таблицы, топики Kafka версионированы, сквозной UUID пользователя проходит от авторизации до рекомендаций, внутренние сервисы принимают запросы только с HMAC-подписью шлюза.

## Подсистемы

| Подсистема | Стек | Ответственность |
|---|---|---|
| content-aggregation-system | Kotlin, Spring Boot 3.4 | конфигурация источников, парсинг Telegram и веба, публикация контента через REST |
| dedup-system | Python 3.12 | GPU-воркер: поиск почти-дубликатов по эмбеддингам, граф похожестей |
| rec-system | Python 3.12, FastAPI | NLP-признаки, профили интересов, ранжирование ленты |
| backend | Kotlin, Spring Boot 3.4, 6 микросервисов | шлюз API, авторизация, профили, события, подписки, сборка ленты |
| frontend-app | Dart 3, Flutter 3 | клиент Android + Web: регистрация, онбординг, лента, коллекции |

## Что здесь интересного

- Шлюз на Spring WebFlux: JWT с отзывом токенов и rate limiting через Valkey, HMAC-подпись `X-Gateway-Signature`, за шлюзом внутренние сервисы наружу не торчат.
- Kafka 7.9 в KRaft-режиме без Zookeeper: семь топиков, JSON в бэкенде и Protobuf в контент-пайплайне, transactional outbox в сервисах авторизации, пользователей и подписок.
- PostgreSQL 17 + pgvector с HNSW-индексами: эмбеддинги живут в БД, бенчмарк индекса в `scripts/hnsw_demo` (замеры до/после). Каждая подсистема владеет своей схемой и чужого не пишет, таблица взаимодействий партиционирована помесячно.
- Дедупликация на GPU: BGE-M3 FP16 (1024-dim), точное сравнение по SHA-256 плюс пороговый классификатор EXACT / DUPLICATE / RELATED, результат — граф похожестей, на который опирается рекомендер.
- Рекомендации на rubert-tiny2 (312-dim) с тематикой, тональностью и NER: профиль интересов пересчитывается по потоку событий из Kafka, ответ ранкера содержит разбивку скоринга по компонентам — видно, почему пост попал в ленту.
- Наблюдаемость: Prometheus-метрики со всех сервисов, структурные JSON-логи с `request_id` и `user_id`; шлюз выпускает `X-Request-Id` на каждый запрос и протаскивает его через всю цепочку вызовов.
- Тесты: около 630 автотестов в ML-подсистемах (dedup ~180, rec-system ~450) на Testcontainers, бэкенд под JUnit 5 + MockK + Testcontainers, во Flutter widget- и unit-тесты с golden-сравнением экранов.
- Деплой: полный стек поднимается одним `docker compose up -d` (инфраструктура, миграции Liquibase/Alembic, 11 сервисов), для Kubernetes есть манифесты под k3d/k3s с миграциями в виде Job.

## Запуск

Нужны Docker с Compose-плагином и примерно 8 ГБ свободной памяти. Скопируйте переменные окружения и поднимайте стек:

```bash
cp backend/.env.example .env   # заполнить SMTP/платёжные переменные при необходимости
docker compose up -d
```

Варианты попроще: `docker-compose.ml.yml` (только ML-пайплайн) и `docker-compose.smoke.yml` (минимальный смоук-стек). Манифесты Kubernetes лежат в `infrastructure/k8s/`, подробности деплоя и e2e-тест конвейера данных описаны в [docs/README.en.md](docs/README.en.md).

## Структура репозитория

```
skd-content-platform/
├── backend/                    # 6 микросервисов Kotlin/Spring Boot
├── content-aggregation-system/ # контент-пайплайн (config, parser, aggregator)
├── dedup-system/               # GPU-воркер дедупликации
├── rec-system/                 # рекомендательный сервис FastAPI
├── frontend-app/               # Flutter-клиент (Android + Web)
├── infrastructure/             # k8s-манифесты, gateway, postgres, seaweedfs
├── scripts/                    # сиды источников, миграции, e2e-тест, hnsw_demo
├── docs/                       # подробный README на английском
├── docker-compose.yml          # полный стек
└── data-capture-spec.md        # спецификация сквозной интеграции
```

Подробное техническое описание: архитектурные правила, владение таблицами, топики Kafka, потоки данных и модель разработки — в [docs/README.en.md](docs/README.en.md).
