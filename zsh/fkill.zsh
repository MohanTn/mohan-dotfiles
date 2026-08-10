# Fuzzy-pick a listening port/service/PID from lsof and kill -9 it
fkill() {
  sudo lsof -i -P -n | fzf --header="Type a PORT (e.g. :8080), Service, or PID" | awk '{print $2}' | xargs -r sudo kill -9
  # scaffold:inject
}
