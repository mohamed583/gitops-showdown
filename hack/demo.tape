# hack/demo.tape -- the recording at the top of the README.
#
# Rendered with VHS (https://github.com/charmbracelet/vhs):
#
#     vhs hack/demo.tape
#
# VHS needs ttyd and ffmpeg on PATH. The bench must already be up:
#
#     make up
#
# KNOWN LIMITATION: VHS does not work on Windows. `vhs validate` passes and
# `vhs hack/demo.tape` prints "Creating docs/assets/showdown.gif..." and exits 0,
# but no file is written -- reproduced on a minimal tape too. Render on macOS,
# Linux or WSL.
#
# This tape is READ-ONLY against the clusters. It deliberately does NOT run
# hack/demo-converge.sh: that takes about six minutes, almost all of it waiting
# out Argo CD's three-minute default poll interval, which makes for a long GIF
# of nothing happening. Run that one live.

Output docs/assets/showdown.gif

Set Shell bash
Set FontSize 16
Set Width 1200
Set Height 700
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 24ms

Hide
Type "cd $(git rev-parse --show-toplevel) && clear" Enter
Sleep 2s
Show

Type "# One application. Two GitOps engines. One identical Helm chart." Enter
Sleep 2500ms

Type "make status" Enter
Sleep 11s

Type "clear" Enter
Sleep 400ms
Type "# Both engines serve the same commit. So what actually differs?" Enter
Sleep 2500ms

Type "make diverge" Enter
Sleep 13s

Type "clear" Enter
Sleep 400ms
Type "# Flux ran a real helm upgrade. There is a release, with history." Enter
Sleep 2s
Type "helm history ticketflow --kube-context kind-showdown-flux -n ticketflow" Enter
Sleep 7s

Type "# Argo CD rendered the chart itself. There is no release at all." Enter
Sleep 2s
Type "helm list --kube-context kind-showdown-argocd -n ticketflow" Enter
Sleep 6s

Type "clear" Enter
Sleep 400ms
Type "# Every trade-off is written down, measured or sourced." Enter
Sleep 2s
Type "ls docs docs/adr" Enter
Sleep 7s
