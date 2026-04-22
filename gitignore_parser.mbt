///|
pub struct Rule {
  line : Int
  original : String
  pattern : String
  negated : Bool
  directory_only : Bool
  anchored : Bool
  has_slash : Bool
} derive(Eq, Debug)

///|
pub fn Rule::matchs(self : Rule, path : String) -> Bool {
  let directory_hint = path.has_suffix("/") || path.has_suffix("\\")
  let normalized = normalize_path(path)
  let match_pattern = self.match_pattern()
  guard !normalized.is_empty() else { return false }
  if self.directory_only {
    if directory_hint && self.matchs_core(normalized, match_pattern) {
      return true
    }
    any_parent_match(self, normalized, match_pattern)
  } else {
    if self.matchs_core(normalized, match_pattern) {
      return true
    }
    any_parent_match(self, normalized, match_pattern)
  }
}

///|
pub fn parse(content : String) -> Array[Rule] {
  let rules = []
  for rest = content[:], line_number = 1 {
    lexmatch rest {
      "" => break rules
      (("[^\n]*" as line) "\n", next) => {
        match parse_line_view(line, line_number) {
          Some(rule) => rules.push(rule)
          None => ()
        }
        continue next, line_number + 1
      }
      ("[^\n]*" as line) => {
        match parse_line_view(line, line_number) {
          Some(rule) => rules.push(rule)
          None => ()
        }
        break rules
      }
      _ => panic()
    }
  }
}

///|
pub fn parse_line(line : String, line_number : Int) -> Rule? {
  parse_line_view(line[:], line_number)
}

///|
fn Rule::match_pattern(self : Rule) -> String {
  let trimmed = trim_unescaped_trailing_spaces(self.original[:])
  let chars = trimmed.to_array()
  let mut start = 0
  if self.negated && start < chars.length() && chars[start] == '!' {
    start += 1
  }
  if self.anchored && start < chars.length() && chars[start] == '/' {
    start += 1
  }

  let mut end = chars.length()
  if self.directory_only &&
    end > start &&
    chars[end - 1] == '/' &&
    !is_escaped(chars, end - 1, start) {
    end -= 1
  }
  char_slice_to_string(chars, start, end)
}

///|
fn any_parent_match(rule : Rule, path : String, pattern : String) -> Bool {
  let chars = path.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      let parent = path.unsafe_substring(start=0, end=i)
      if rule.matchs_core(parent, pattern) {
        return true
      }
    }
  }
  false
}

///|
fn Rule::matchs_core(self : Rule, path : String, pattern : String) -> Bool {
  guard !pattern.is_empty() else { return path.is_empty() }
  if self.anchored {
    if self.has_slash {
      glob_match(pattern, path)
    } else {
      !path.contains("/") && glob_match(pattern, path)
    }
  } else if self.has_slash {
    if glob_match(pattern, path) {
      true
    } else {
      let chars = path.to_array()
      let mut matched = false
      for i in 0..<chars.length() {
        if chars[i] == '/' {
          let suffix = path.unsafe_substring(start=i + 1, end=path.length())
          if glob_match(pattern, suffix) {
            matched = true
            break
          }
        }
      }
      matched
    }
  } else {
    let segments = split_path_segments(path)
    for segment in segments {
      if glob_match(pattern, segment) {
        return true
      }
    }
    false
  }
}

///|
fn split_path_segments(path : String) -> Array[String] {
  let segments = []
  for segment in path.split("/") {
    let item = segment.to_string()
    if !item.is_empty() && item != "." {
      segments.push(item)
    }
  }
  segments
}

///|
fn normalize_path(path : String) -> String {
  let unix_path = path.replace_all(old="\\", new="/")
  let mut view = unix_path[:]
  while view.strip_prefix("./") is Some(next) {
    view = next
  }

  let chars = view.to_array()
  let mut end = chars.length()
  while end > 0 && chars[end - 1] == '/' {
    end -= 1
  }

  if end == chars.length() {
    view.to_string()
  } else {
    char_slice_to_string(chars, 0, end)
  }
}

///|
priv enum GlobToken {
  Literal(Char)
  Question
  Star
  DoubleStar
  CharClass(Bool, Array[ClassEntry])
}

///|
priv enum ClassEntry {
  Single(Char)
  Range(start~ : Char, end~ : Char)
}

///|
fn tokenize_glob(pattern : String) -> Array[GlobToken] {
  let chars = pattern.to_array()
  let tokens = []
  let mut i = 0
  while i < chars.length() {
    let current = chars[i]
    if current == '\\' {
      if i + 1 < chars.length() {
        tokens.push(Literal(chars[i + 1]))
        i += 2
      } else {
        tokens.push(Literal('\\'))
        i += 1
      }
    } else if current == '[' {
      let (class_token, next_index) = parse_char_class(chars, i)
      match class_token {
        Some(token) => {
          tokens.push(token)
          i = next_index
        }
        None => {
          tokens.push(Literal('['))
          i += 1
        }
      }
    } else if current == '*' &&
      i + 1 < chars.length() &&
      chars[i + 1] == '*' &&
      is_special_double_star(chars, i) {
      tokens.push(DoubleStar)
      i += 2
    } else if current == '?' {
      tokens.push(Question)
      i += 1
    } else if current == '*' {
      tokens.push(Star)
      i += 1
    } else {
      tokens.push(Literal(current))
      i += 1
    }
  }
  tokens
}

///|
fn parse_char_class(chars : Array[Char], start : Int) -> (GlobToken?, Int) {
  let mut i = start + 1
  let mut negated = false
  if i < chars.length() && (chars[i] == '!' || chars[i] == '^') {
    negated = true
    i += 1
  }

  let entries = []
  let mut has_entry = false

  while i < chars.length() {
    if chars[i] == ']' && has_entry {
      return (Some(CharClass(negated, entries)), i + 1)
    }

    let (start_char, next_index) = parse_class_char(chars, i)
    i = next_index

    if i < chars.length() &&
      chars[i] == '-' &&
      i + 1 < chars.length() &&
      chars[i + 1] != ']' {
      let (end_char, next_end) = parse_class_char(chars, i + 1)
      entries.push(Range(start=start_char, end=end_char))
      i = next_end
    } else {
      entries.push(Single(start_char))
    }
    has_entry = true
  }

  (None, start + 1)
}

///|
fn parse_class_char(chars : Array[Char], index : Int) -> (Char, Int) {
  if chars[index] == '\\' && index + 1 < chars.length() {
    (chars[index + 1], index + 2)
  } else {
    (chars[index], index + 1)
  }
}

///|
fn is_special_double_star(chars : Array[Char], start : Int) -> Bool {
  let end = start + 2
  let left_boundary = start == 0 ||
    (chars[start - 1] == '/' && !is_escaped(chars, start - 1, 0))
  let right_boundary = end == chars.length() ||
    (chars[end] == '/' && !is_escaped(chars, end, 0))
  left_boundary && right_boundary
}

///|
fn class_contains(entries : Array[ClassEntry], ch : Char) -> Bool {
  for entry in entries {
    match entry {
      Single(value) => if value == ch { return true }
      Range(start~, end~) =>
        if start <= end {
          if start <= ch && ch <= end {
            return true
          }
        } else if end <= ch && ch <= start {
          return true
        }
    }
  }
  false
}

///|
fn glob_match(pattern : String, text : String) -> Bool {
  let tokens = tokenize_glob(pattern)
  let chars = text.to_array()
  let token_len = tokens.length()
  let char_len = chars.length()

  let memo = []
  for _ in 0..<=token_len {
    memo.push(Array::make(char_len + 1, -1))
  }

  fn dfs(token_index : Int, char_index : Int) -> Bool {
    let cached = memo[token_index][char_index]
    if cached != -1 {
      cached == 1
    } else {
      let matched = if token_index == token_len {
        char_index == char_len
      } else {
        match tokens[token_index] {
          Literal(ch) =>
            char_index < char_len &&
            chars[char_index] == ch &&
            dfs(token_index + 1, char_index + 1)
          Question =>
            char_index < char_len &&
            chars[char_index] != '/' &&
            dfs(token_index + 1, char_index + 1)
          Star =>
            dfs(token_index + 1, char_index) ||
            (
              char_index < char_len &&
              chars[char_index] != '/' &&
              dfs(token_index, char_index + 1)
            )
          DoubleStar =>
            dfs(token_index + 1, char_index) ||
            (
              token_index + 1 < token_len &&
              tokens[token_index + 1] is Literal('/') &&
              dfs(token_index + 2, char_index)
            ) ||
            (char_index < char_len && dfs(token_index, char_index + 1))
          CharClass(negated, entries) =>
            char_index < char_len &&
            chars[char_index] != '/' &&
            ({
              let contains = class_contains(entries, chars[char_index])
              if negated {
                !contains
              } else {
                contains
              }
            }) &&
            dfs(token_index + 1, char_index + 1)
        }
      }

      memo[token_index][char_index] = if matched { 1 } else { 0 }
      matched
    }
  }

  dfs(0, 0)
}

///|
fn parse_line_view(line : StringView, line_number : Int) -> Rule? {
  let normalized = trim_cr(line)
  let trimmed = trim_unescaped_trailing_spaces(normalized)
  if trimmed.is_empty() {
    None
  } else {
    lexmatch trimmed {
      ("#", _) => None
      _ => {
        let (negated, no_bang) = lexmatch trimmed {
          ("!", rest) => (true, rest)
          rest => (false, rest)
        }
        let (anchored, raw_pattern) = lexmatch no_bang {
          ("/", rest) => (true, rest)
          rest => (false, rest)
        }
        let (pattern, directory_only, has_slash) = parse_pattern(raw_pattern)
        if pattern.is_empty() {
          None
        } else {
          Some(Rule::{
            line: line_number,
            original: normalized.to_string(),
            pattern,
            negated,
            directory_only,
            anchored,
            has_slash,
          })
        }
      }
    }
  }
}

///|
fn parse_pattern(pattern : StringView) -> (String, Bool, Bool) {
  let chars = pattern.to_array()
  let mut end = chars.length()
  let mut directory_only = false
  if end > 0 && chars[end - 1] == '/' && !is_escaped(chars, end - 1, 0) {
    directory_only = true
    end -= 1
  }

  let mut has_slash = false
  for i in 0..<end {
    if chars[i] == '/' {
      has_slash = true
      break
    }
  }

  (unescape_range(chars, 0, end), directory_only, has_slash)
}

///|
fn trim_cr(line : StringView) -> StringView {
  match line.strip_suffix("\r") {
    Some(view) => view
    None => line
  }
}

///|
fn trim_unescaped_trailing_spaces(line : StringView) -> String {
  let chars = line.to_array()
  let mut end = chars.length()
  while end > 0 {
    let last = end - 1
    guard chars[last] == ' ' && !is_escaped(chars, last, 0) else { break }
    end -= 1
  }
  if end == chars.length() {
    line.to_string()
  } else {
    char_slice_to_string(chars, 0, end)
  }
}

///|
fn unescape_range(chars : Array[Char], start : Int, end : Int) -> String {
  let result = []
  let mut i = start
  while i < end {
    if chars[i] == '\\' && i + 1 < end {
      result.push(chars[i + 1])
      i += 2
    } else {
      result.push(chars[i])
      i += 1
    }
  }
  String::from_array(result)
}

///|
fn char_slice_to_string(chars : Array[Char], start : Int, end : Int) -> String {
  let result = []
  for i in start..<end {
    result.push(chars[i])
  }
  String::from_array(result)
}

///|
fn is_escaped(chars : Array[Char], index : Int, start : Int) -> Bool {
  let mut slash_count = 0
  let mut i = index - 1
  while i >= start && chars[i] == '\\' {
    slash_count += 1
    i -= 1
  }
  slash_count % 2 == 1
}
