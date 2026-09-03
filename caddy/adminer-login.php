<?php
/**
 * Adminer auto-login for the dev database.
 *
 * A login form between a developer and their own throwaway dev database is pure
 * friction, and the friction has a cost that is not obvious: people route around
 * it by running ad-hoc SQL as root in a shell, where there is no query history,
 * no result grid, and nothing stopping a missing WHERE clause.
 *
 * Credentials come from the environment the container was started with, so this
 * file contains no secrets and is safe to commit. It only ever works against the
 * stack's own database container.
 */
class AdminerLoginPasswordLess extends Adminer\Plugin
{
    function credentials()
    {
        return [
            getenv('ADMINER_DEFAULT_SERVER') ?: 'mysql',
            getenv('DB_USER') ?: 'root',
            getenv('DB_PASSWORD') ?: '',
        ];
    }

    function login($login, $password)
    {
        return true;
    }

    function database()
    {
        return getenv('DB_NAME') ?: null;
    }
}
