///|
fn is_ignored_by_rules(rules : Array[Rule], path : String) -> Bool {
  let mut ignored = false
  for rule in rules {
    if rule.matchs(path) {
      ignored = !rule.negated
    }
  }
  ignored
}

///|
test "parse ignores comments and blanks" {
  let content =
    #|# comment
    #|
    #|\#literal
    #|foo
  let rules = parse(content)
  assert_eq(rules.length(), 2)

  assert_eq(rules[0].line, 3)
  assert_eq(rules[0].pattern, "#literal")
  assert_eq(rules[0].negated, false)
  assert_eq(rules[0].directory_only, false)

  assert_eq(rules[1].line, 4)
  assert_eq(rules[1].pattern, "foo")
  assert_eq(rules[1].has_slash, false)
}

///|
test "parse negation, anchoring and slash flags" {
  let content =
    #|!important.log
    #|/build/
    #|foo/bar
  let rules = parse(content)
  assert_eq(rules.length(), 3)

  assert_eq(rules[0].pattern, "important.log")
  assert_eq(rules[0].negated, true)

  assert_eq(rules[1].pattern, "build")
  assert_eq(rules[1].anchored, true)
  assert_eq(rules[1].directory_only, true)
  assert_eq(rules[1].has_slash, false)

  assert_eq(rules[2].pattern, "foo/bar")
  assert_eq(rules[2].has_slash, true)
  assert_eq(rules[2].anchored, false)
}

///|
test "parse handles trailing spaces" {
  let rules = parse("space   \nname\\ \n")
  assert_eq(rules.length(), 2)

  assert_eq(rules[0].pattern, "space")
  assert_eq(rules[1].pattern, "name ")
}

///|
test "escaped slash is not directory marker" {
  let parsed = parse_line("foo\\/", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.pattern, "foo/")
      assert_eq(rule.directory_only, false)
      assert_eq(rule.has_slash, true)
    }
    None => panic()
  }
}

///|
test "parse supports CRLF and preserves line numbers" {
  let rules = parse("a\r\nb\r\n# comment\r\n")
  assert_eq(rules.length(), 2)

  assert_eq(rules[0].line, 1)
  assert_eq(rules[0].original, "a")
  assert_eq(rules[0].pattern, "a")

  assert_eq(rules[1].line, 2)
  assert_eq(rules[1].original, "b")
  assert_eq(rules[1].pattern, "b")
}

///|
test "escaped prefix markers are treated as literals" {
  let content =
    #|\!keep
    #|\#keep
  let rules = parse(content)
  assert_eq(rules.length(), 2)

  assert_eq(rules[0].negated, false)
  assert_eq(rules[0].pattern, "!keep")

  assert_eq(rules[1].pattern, "#keep")
}

///|
test "even and odd backslashes before trailing space" {
  let odd = parse_line("name\\ ", 1)
  let even = parse_line("name\\\\ ", 1)
  assert_eq(odd is Some(_), true)
  assert_eq(even is Some(_), true)

  match odd {
    Some(rule) => assert_eq(rule.pattern, "name ")
    None => panic()
  }
  match even {
    Some(rule) => assert_eq(rule.pattern, "name\\")
    None => panic()
  }
}

///|
test "anchored directory with nested path keeps has_slash" {
  let parsed = parse_line("/foo/bar/", 7)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.line, 7)
      assert_eq(rule.anchored, true)
      assert_eq(rule.directory_only, true)
      assert_eq(rule.has_slash, true)
      assert_eq(rule.pattern, "foo/bar")
    }
    None => panic()
  }
}

///|
test "lone bang is ignored as invalid pattern" {
  let parsed = parse_line("!", 3)
  assert_eq(parsed is None, true)
}

///|
test "Rule::matchs supports basename matching" {
  let parsed = parse_line("*.log", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("app.log"), true)
      assert_eq(rule.matchs("src/app.log"), true)
      assert_eq(rule.matchs("app.txt"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs respects anchored patterns" {
  let parsed = parse_line("/build", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("build"), true)
      assert_eq(rule.matchs("src/build"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs handles slash patterns and double star" {
  let parsed = parse_line("**/cache/*.tmp", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("cache/a.tmp"), true)
      assert_eq(rule.matchs("a/b/cache/x.tmp"), true)
      assert_eq(rule.matchs("a/b/cache/x.txt"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs supports directory only rules" {
  let parsed = parse_line("build/", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("build/"), true)
      assert_eq(rule.matchs("build/output.o"), true)
      assert_eq(rule.matchs("src/build/output.o"), true)
      assert_eq(rule.matchs("build"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs ignores negation flag and only checks match itself" {
  let parsed = parse_line("!keep.txt", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.negated, true)
      assert_eq(rule.matchs("keep.txt"), true)
      assert_eq(rule.matchs("drop.txt"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs treats escaped wildcard as literal" {
  let parsed = parse_line("\\*.log", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("*.log"), true)
      assert_eq(rule.matchs("app.log"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs only treats ** as special at path-component boundaries" {
  let parsed = parse_line("dir/**b", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("dir/ab"), true)
      assert_eq(rule.matchs("dir/x/ab"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs supports character classes" {
  let parsed = parse_line("[ab].txt", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.matchs("a.txt"), true)
      assert_eq(rule.matchs("b.txt"), true)
      assert_eq(rule.matchs("c.txt"), false)
      assert_eq(rule.matchs("[ab].txt"), false)
    }
    None => panic()
  }
}

///|
test "Rule::matchs handles escaped slash in the middle of a pattern" {
  let parsed = parse_line("foo\\/bar", 1)
  assert_eq(parsed is Some(_), true)

  match parsed {
    Some(rule) => {
      assert_eq(rule.has_slash, true)
      assert_eq(rule.matchs("foo/bar"), true)
      assert_eq(rule.matchs("bar"), false)
    }
    None => panic()
  }
}

///|
test "parse skips invalid empty patterns created by prefixes" {
  let content =
    #|!
    #|/
    #|!/
    #|valid
  let rules = parse(content)
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].line, 4)
  assert_eq(rules[0].pattern, "valid")
}

///|
test "rules are applied in order and the last matching rule wins" {
  let content =
    #|*.log
    #|!keep.log
    #|keep.log
  let rules = parse(content)

  assert_eq(is_ignored_by_rules(rules, "error.log"), true)
  assert_eq(is_ignored_by_rules(rules, "keep.log"), true)
}

///|
test "negation can unignore when it is the last matching rule" {
  let content =
    #|*.log
    #|!keep.log
  let rules = parse(content)

  assert_eq(is_ignored_by_rules(rules, "error.log"), true)
  assert_eq(is_ignored_by_rules(rules, "keep.log"), false)
}
