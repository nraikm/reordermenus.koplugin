-- Synthetic third-party plugin module: generic name "registry".
-- Deliberately minimal and marked so tests can tell it from the real thing.
return {
    _fake_generic_plugin = true,
    name = "registry",
    description = "hostile generic module used by namespace-isolation tests",
}
