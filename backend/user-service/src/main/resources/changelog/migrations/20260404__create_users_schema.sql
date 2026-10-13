-- liquibase formatted sql
-- changeset agenticflow:20260404__create_users_schema

CREATE SCHEMA IF NOT EXISTS users;
-- rollback DROP SCHEMA IF EXISTS users CASCADE;
