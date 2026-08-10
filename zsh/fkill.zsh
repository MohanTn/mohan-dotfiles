  sudo lsof -i -P -n -sTCP:LISTEN | fzf --header="Type a PORT (e.g. :8080), Service, or PID" | awk '{print $2}' | xargs -r sudo kill -9
  # scaffold:inject
}
