# Shared full-manifest validator — THE single source of the manifest schema.
# Consumed by engine/converge.sh and scripts/assist-play.sh via
#   jq -e --argjson writableFlags <json-array> -f validate-manifest.jq MANIFEST
# (writableFlags comes from read-state.sh's writable_permission_flags array).
# History: the version check was once duplicated in assist-play.sh and missed
# a manifestVersion bump — found by the bench, 2026-07-19. One schema, one file.
  def strings: type == "array" and all(.[]; type == "string");
  def package: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\\z");
  def permission: type == "string" and test("^[A-Za-z0-9_.]+\\z");
  def appop: type == "string" and test("^[A-Z][A-Z0-9_]*\\z");
  def component: type == "string" and test("^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+/[.]?[A-Za-z0-9_$]+([.][A-Za-z0-9_$]+)*\\z");
  def locale: type == "string" and length <= 100 and test("^[a-z]{2,8}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?(-([a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*(-[0-9a-wy-z](-[a-z0-9]{2,8})+)*(-x(-[a-z0-9]{1,8})+)?\\z");
  def domain: type == "string" and length <= 253 and test("^(\\*\\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\\z");
  def packages: strings and all(.[]; package);
  def is_unique: length == (unique | length);
  (keys == ["android", "apps", "device", "manifestVersion"])
  and (.manifestVersion == 3 or .manifestVersion == 4)
  and (.device | type == "object"
    and (keys == ["abi", "name", "user"])
    and (.name | type == "string" and test("^[A-Za-z0-9._-]+\\z"))
    and .user == 0
    and (.abi | IN("arm64-v8a", "armeabi-v7a", "x86_64")))
  and (.apps | type == "object"
    and (keys == ["attended", "cleanup", "managed", "play"])
    and (.cleanup | IN("none", "report", "uninstall"))
    and (.attended | packages)
    and (.play | packages)
    and (.managed | type == "array" and all(.[];
      type == "object"
      and (keys == ["apk", "package", "versionCode"])
      and (.package | package)
      and (.versionCode | type == "number" and . >= 0 and floor == .)
      and (.apk | type == "string" and startswith("/")))))
  and (.android | type == "object"
    and (keys == ["appLinks", "appOps", "darkMode", "dataSaver", "deviceidleExempt", "disabled", "inputMethod", "locales", "permissions", "roles", "settings", "suspended", "unsuspended"]
      or keys == ["appLinks", "appOps", "darkMode", "dataSaver", "deviceidleExempt", "deviceidleUnexempt", "disabled", "inputMethod", "locales", "permissions", "roles", "settings", "suspended", "unsuspended"])
    and (.darkMode | . == null or type == "boolean")
    and (.disabled | packages and is_unique)
    and (.suspended | packages and is_unique)
    and (.unsuspended | packages and is_unique)
    and ((.suspended + .unsuspended) | is_unique)
    and (.deviceidleExempt | packages and is_unique)
    and ((.deviceidleUnexempt // []) | packages and is_unique)
    and ((.deviceidleExempt + (.deviceidleUnexempt // [])) | is_unique)
    and (.roles | type == "object" and all(to_entries[];
      (.key | IN("browser", "sms", "dialer", "home"))
      and (.value | package)))
    and (.settings | type == "object"
      and (keys == ["global", "secure", "system"])
      and all(to_entries[];
      (.key | IN("global", "secure", "system"))
      and (.value | type == "object" and all(to_entries[];
        (.key | type == "string" and test("^[A-Za-z0-9_.-]+\\z"))
        and (.value | type == "string" and length > 0 and . != "null"
          and (contains("\u0000") | not)
          and (contains("\n") | not)
          and (contains("\r") | not)
          and (contains("\u001f") | not))))))
    and (.permissions | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object"
        and (keys == ["flags", "grant", "revoke"])
        and (.grant | strings and all(.[]; permission))
        and (.revoke | strings and all(.[]; permission))
        and ((.grant + .revoke) | is_unique)
        and (.flags | type == "object" and all(to_entries[];
          (.key | permission)
          and (.value | strings and is_unique and all(.[];
            IN($writableFlags[]))))))))
    and (.appOps | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object" and all(to_entries[];
        (.key | appop)
        and (.value | IN("allow", "ignore", "deny", "default", "foreground"))))))
    and (.locales | type == "object" and all(to_entries[];
      (.key | package) and (.value | strings and is_unique and all(.[]; locale))))
    and (.inputMethod | type == "object"
      and (keys == ["default", "disabled", "enabled"])
      and (.default | . == null or component)
      and (.enabled | strings and is_unique and all(.[]; component))
      and (.disabled | strings and is_unique and all(.[]; component))
      and ((.enabled + .disabled) | is_unique)
      and (.default as $default | $default == null or (.enabled | index($default)) != null))
    and (.dataSaver | type == "object"
      and (keys == ["enabled"])
      and (.enabled | . == null or type == "boolean"))
    and (.appLinks | type == "object" and all(to_entries[];
      (.key | package)
      and (.value | type == "object"
        and (keys == ["allowed", "selected", "unselected"])
        and (.allowed | . == null or type == "boolean")
        and (.selected | strings and is_unique and all(.[]; domain))
        and (.unselected | strings and is_unique and all(.[]; domain))
        and ((.selected + .unselected) | is_unique))))
    and ([.appLinks[].selected[]] | is_unique))
  and (([.apps.managed[].package] + .apps.attended + .apps.play) | is_unique)
