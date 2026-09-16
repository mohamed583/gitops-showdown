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
# This tape only READS from the clusters and pushes one commit. It is safe to
# re-run; `git revert` afterwards puts the chart back.

Output docs/assets/showdown.gif

Set Shell bash
Set FontSize 15
Set Width 1160
Set Height 680
Set Padding 22
Set Theme "Catppuccin Mocha"
Set TypingSpeed 28ms
Set PlaybackSpeed 1.0

Hide
Type "cd $(git rev-parse --show-toplevel) && clear" Enter
Sleep 1s
Show

Type "# One application. Two GitOps engines. One identical Helm chart." Enter
Sleep 2s
Type "make status" Enter
Sleep 9s

Type "clear" Enter
Sleep 500ms
Type "# Both engines are serving the same commit. So what is different?" Enter
Sleep 2s
Type "make diverge" Enter
Sleep 12s

Type "clear" Enter
Sleep 500ms
Type "# Flux left a Helm release. Argo CD left none. Same chart, same commit." Enter
Sleep 3s
Type "helm history ticketflow --kube-context kind-showdown-flux -n ticketflow" Enter
Sleep 5s
Type "helm list --kube-context kind-showdown-argocd -n ticketflow" Enter
Sleep 5s

Type "clear" Enter
Sleep 500ms
Type "# Now commit a change and watch both engines converge on it." Enter
Sleep 2s
Type "hack/demo-converge.sh" Enter
Sleep 75s

Type "clear" Enter
Sleep 500ms
Type "# The trade-offs are written down, with sources." Enter
Sleep 2s
Type "ls docs/ docs/adr/" Enter
Sleep 6s
