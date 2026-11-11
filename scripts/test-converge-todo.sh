#!/usr/bin/env bash
# Static guard for converge.sh's plan categories (engine-parsers check): every
# declared todo_* array must be in todo_arrays (which the change count
# iterates), and every listed array must be consumed by at least two loops, its
# plan line and its apply action. A category added in one place only would
# otherwise print "device matches manifest" or plan a change it never applies.
set -euo pipefail

engine=${1:?usage: test-converge-todo.sh ENGINE}
fail() { echo "test-converge-todo: $*" >&2; exit 1; }

declared=$(grep -oE '^todo_[a-z_]+=\(\)' "$engine" | sed 's/=()$//' | sort)
listed=$(sed -n '/^todo_arrays=($/,/^)$/p' "$engine" | sed '1d;$d' | tr -s ' ' '\n' | sed '/^$/d' | sort)
[ -n "$listed" ] || fail "no todo_arrays=( ... ) list found in $engine"
[ "$declared" = "$listed" ] || {
  echo "declared (left) vs todo_arrays (right):" >&2
  comm -3 <(printf '%s\n' "$declared") <(printf '%s\n' "$listed") >&2
  fail "todo_* declarations and todo_arrays disagree"
}
while read -r name; do
  uses=$(grep -cF "\"\${${name}[@]}\"" "$engine" || true)
  [ "$uses" -ge 2 ] || fail "$name has $uses consuming loop(s); needs a plan line and an apply action"
done <<<"$listed"

# Self-test: the guard must reject an array declared but left out of the list.
mutant=$(mktemp)
trap 'rm -f "$mutant"' EXIT
sed 's/^todo_unidle=()/todo_unidle=()\ntodo_forgotten=()/' "$engine" >"$mutant"
if bash "$0" "$mutant" 2>/dev/null; then
  fail "guard accepted an unlisted todo_forgotten array"
fi

echo "converge todo-array guard passed"
