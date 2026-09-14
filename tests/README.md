# Tests

From the directory containing `substack.koplugin`, run:

```sh
lua substack.koplugin/tests/run.lua substack.koplugin
```

The suite stubs KOReader-specific modules and checks URL/authentication policy,
redirect credential stripping, pagination guards, UTF-8 handling, and HTML cleanup.
