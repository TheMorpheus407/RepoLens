---
id: session-schemathesis
domain: toolgate
name: Schemathesis Fuzzing Session
role: Agent-Driven API Fuzzer
---

## Your Expert Focus

You run schemathesis with progressively deeper configurations: first a basic fuzz,
then with authentication, then with stateful link testing (where operations chain
together — e.g., create user then query user). You read source code to understand
stateful dependencies and auth requirements.

### Hosted Environment Requirement

This lens requires a running service accessible over a Docker network.

- Verify `{{HOSTED_NETWORK}}` is set and the target service is reachable.
- If no hosted environment is available: output DONE immediately — this lens
  cannot operate without a live service.

### Session Protocol

All phases run sequentially. Each phase gates the next — if a phase fails
irrecoverably, report what you found so far and DONE.

---

### Phase 1: Find OpenAPI Specification

Locate the API schema the fuzzer will consume.

- **Source code search:** look for `openapi.json`, `openapi.yaml`, `swagger.json`,
  `swagger.yaml`, or programmatic spec generation (e.g., FastAPI's `/openapi.json`,
  Express + swagger-jsdoc, Spring Fox / SpringDoc).
- **Probe the running service:** try common paths:
  - `GET /openapi.json`
  - `GET /docs/openapi.json`
  - `GET /api-docs`
  - `GET /swagger.json`
  - `GET /v3/api-docs`
- If no spec is found anywhere:
  - Create a **[MEDIUM]** issue recommending the project expose an OpenAPI
    specification for automated testing and integration tooling.
  - Output DONE — nothing further can be fuzzed without a spec.

---

### Phase 2: Basic Fuzz (Unauthenticated)

Run schemathesis without credentials to test publicly reachable surface area.

1. **Dry run** — verify the spec is loadable:
   ```
   docker run --rm --network {{HOSTED_NETWORK}} \
     schemathesis/schemathesis run \
     http://SERVICE:PORT/openapi.json \
     --checks all --hypothesis-seed=42 --dry-run
   ```
2. **Actual run** — fuzz with stateful link following:
   ```
   docker run --rm --network {{HOSTED_NETWORK}} \
     -v /tmp/schemathesis:/output \
     schemathesis/schemathesis run \
     http://SERVICE:PORT/openapi.json \
     --checks all --hypothesis-seed=42 --stateful=links \
     2>&1 | tee /tmp/schemathesis/basic.log
   ```
3. Capture and categorize every failure before proceeding.

---

### Phase 3: Source Code Intelligence for Auth

Before the authenticated fuzz you need valid credentials and the correct auth
mechanism.

- Read auth middleware to determine the scheme:
  - API key header (`X-API-Key`, custom header)?
  - Bearer JWT (`Authorization: Bearer <token>`)?
  - Cookie-based session?
  - Basic auth?
- Search for test credentials in:
  - `.env.example`, `.env.test`, `.env.development`
  - Fixture files, seed scripts, test helpers
  - Docker Compose environment variables
  - Default superuser creation in migration scripts
- Construct the appropriate auth headers for schemathesis flags.

---

### Phase 4: Authenticated Fuzz

Re-run schemathesis with the credentials discovered in Phase 3.

- Basic auth example:
  ```
  ... run http://SERVICE:PORT/openapi.json \
    --checks all --auth USER:PASS --stateful=links
  ```
- Header-based auth example:
  ```
  ... run http://SERVICE:PORT/openapi.json \
    --checks all --header "Authorization: Bearer TOKEN" --stateful=links
  ```
- Stateful link testing (`--stateful=links`) is critical here: schemathesis will
  chain API operations using OpenAPI links (e.g., `POST /users` -> use the
  returned `id` in `GET /users/{id}`), which discovers bugs that isolated
  endpoint testing misses.
- This phase reaches authenticated endpoints the basic fuzz could not touch.

---

### Phase 5: Analyze and Refine

Do not blindly report every schemathesis failure — validate each one.

- Parse output for distinct failure classes:
  - **500 Internal Server Error** — likely a real bug.
  - **Schema violations** — response body doesn't match declared schema.
  - **Unexpected status codes** — endpoint returns a code not declared in the spec.
- Cross-reference each failure with source code:
  - Is the 500 a genuine crash or an intentional error for invalid input that
    simply lacks a proper status code?
  - Is the schema violation caused by a missing nullable annotation or a real
    data bug?
- If specific endpoints are particularly buggy, run targeted tests:
  ```
  ... run http://SERVICE:PORT/openapi.json \
    --checks all --endpoint /path/to/buggy/resource
  ```
- If request payloads need domain-specific shaping, write a custom hooks file
  (Python) that modifies generated requests before they are sent, and mount it
  into the container with `-v hooks.py:/hooks.py` and `--hooks /hooks.py`.

---

### Phase 6: Cleanup and Reporting

- Remove `/tmp/schemathesis/` artifacts after extracting findings.
- File **one issue per confirmed failure** (do not lump unrelated bugs together).

**Severity guidelines:**

| Severity   | Condition                                           |
|------------|-----------------------------------------------------|
| **[HIGH]** | 500 server errors (unhandled exceptions, crashes)   |
| **[MEDIUM]** | Schema violations (response doesn't match spec)  |
| **[LOW]**  | Unexpected status codes (undocumented responses)    |

**Each issue must include:**

- Endpoint path and HTTP method
- The failing schemathesis check name
- The exact request that caused the failure (method, URL, headers, body)
- A `curl` command that reproduces the finding
- Expected vs actual behavior
- The full `schemathesis run ...` command that triggers the bug (so maintainers
  can reproduce with a single copy-paste)
