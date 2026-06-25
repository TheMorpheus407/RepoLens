# SQL injection in the user lookup endpoint

## Summary

The `id` query parameter on `GET /users` flows unescaped into a raw SQL string
in `app/users.py`, allowing arbitrary query manipulation.

## Impact

Full read/write access to the primary database via crafted input.

## Recommended Fix

Use parameterized queries or cast `id` to an integer before interpolation.

## References

- https://owasp.org/www-community/attacks/SQL_Injection

## Validation
- attacker_source — HTTP query parameter `id` on GET /users
- missing_guard — no parameterization or integer cast before the query is built
- sink_effect — concatenated into a raw SQL SELECT executed against the primary DB
- preconditions — endpoint is reachable unauthenticated
- proof_anchors — app/users.py:42
- suggested_validation — grep -n "SELECT .* + " app/users.py
