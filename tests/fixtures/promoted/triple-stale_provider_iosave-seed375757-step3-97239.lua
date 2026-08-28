--[==[
Auto-promoted three-way interaction failure.
triple: stale_provider_iosave
seed: 375757
invariants:
  - I7 order: default sibling dictionary_settings should precede wikipedia_settings in search_settings
Replay: SM_SEED_LIST=375757
]==]
return {
  seed = 375757,
  triple = "stale_provider_iosave",
  history = {
    { op = "stage_list_permutation", args = {["menu"]="search_settings",["seq"]={"wikipedia_settings","dictionary_settings"}} },
    { op = "restart", args = {} },
    { op = "stage_list_permutation", args = {["menu"]="search_settings",["seq"]={"dictionary_settings","wikipedia_settings"}} },
  },
}
