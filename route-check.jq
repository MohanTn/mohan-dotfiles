($text | ascii_downcase) as $t
| (.routes // [])
| map(select(.keywords as $k | $k | any(. as $kw | $t | contains($kw | ascii_downcase))))
| sort_by(.priority // 0) | reverse | .[0].file // empty
