-- liquibase formatted sql
-- changeset agenticflow:20260404__create_auth_schema

CREATE SCHEMA IF NOT EXISTS auth;
-- rollback DROP SCHEMA IF EXISTS auth CASCADE;
