# -*- coding: utf-8 -*-
"""
Call-site checker: for every call to a function / initialiser that is DECLARED IN THE PROJECT, verify that the argument labels match at
least one declaration with that name (default values, variadics and trailing closures are honoured). Calls to Apple APIs are ignored.

  python tools/check_calls.py [--root Supercars] [--verbose]

This catches the classic cross-module compile errors of code written without a compiler: wrong / missing labels, wrong argument counts,
memberwise-initialiser mismatches. Because several project functions share names with Apple methods (add, update, play ...) every
report has to be looked at by a human; the line points at the call.
"""
import os
import sys

import tree_sitter_swift
from tree_sitter import Language, Parser

IGNORE = set("append fill index decode load contains sleep clear insert remove add".split())
ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Supercars")
for i, a in enumerate(sys.argv):
    if a == "--root" and i + 1 < len(sys.argv):
        ROOT = os.path.abspath(sys.argv[i + 1])
VERBOSE = "--verbose" in sys.argv

LANG = Language(tree_sitter_swift.language())
PARSER = Parser(LANG)


def txt(n, src):
    return src[n.start_byte:n.end_byte].decode("utf8", "replace")


def walk(node):
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(reversed(n.children))


class Param(object):
    def __init__(self, label, default, variadic, is_func):
        self.label = label          # None for '_'
        self.default = default
        self.variadic = variadic
        self.is_func = is_func

    def __repr__(self):
        return "%s%s%s" % (self.label if self.label else "_", "=" if self.default else "", "..." if self.variadic else "")


def parse_params(fn, src):
    params = []
    kids = list(fn.children)
    i = 0
    while i < len(kids):
        c = kids[i]
        if c.type == "parameter":
            ids = [txt(x, src) for x in c.children if x.type == "simple_identifier"]
            label = ids[0] if ids else None
            if label == "_":
                label = None
            default = i + 1 < len(kids) and kids[i + 1].type == "="
            variadic = any(x.type == "..." or txt(x, src) == "..." for x in c.children)
            body = txt(c, src)
            is_func = "->" in body
            params.append(Param(label, default, variadic, is_func))
        i += 1
    return params


class Decl(object):
    def __init__(self, name, params, where, kind):
        self.name = name
        self.params = params
        self.where = where
        self.kind = kind

    def sig(self):
        return "%s(%s)" % (self.name, ", ".join(("%s:" % (p.label if p.label else "_")) + ("=" if p.default else "") for p in self.params))


def collect(files):
    funcs = {}        # name -> [Decl]
    inits = {}        # type name -> [Decl]
    types = set()
    for f, (tree, src) in files.items():
        rel = os.path.relpath(f, ROOT)
        for n in walk(tree.root_node):
            if n.type == "class_declaration":
                nm = n.child_by_field_name("name")
                kind_tok = next((c.type for c in n.children if c.type in ("struct", "class", "enum", "actor", "extension")), None)
                if nm is None:
                    continue
                tname = txt(nm, src)
                if kind_tok != "extension":
                    types.add(tname)
                body = next((c for c in n.children if c.type in ("class_body", "enum_class_body")), None)
                if body is None:
                    continue
                has_init = False
                stored = []
                for m in body.children:
                    if m.type == "init_declaration":
                        has_init = True
                        inits.setdefault(tname, []).append(Decl(tname, parse_params(m, src), "%s:%d" % (rel, m.start_point[0] + 1), "init"))
                    elif m.type == "property_declaration" and kind_tok == "struct":
                        s = txt(m, src)
                        first = s.strip()
                        if " static " in " " + first or first.startswith("static") or first.startswith("private static") or "lazy " in first:
                            continue
                        if "{" in s and "=" not in s.split("{")[0]:
                            continue                # computed property
                        # stored property: name + default?
                        pname = None
                        for c in m.children:
                            if c.type == "value_binding_pattern":
                                pass
                        for x in walk(m):
                            if x.type == "pattern":
                                pname = txt(x, src).strip()
                                break
                        if pname:
                            is_let = first.split()[0] in ("let",) or " let " in " " + first.split("=")[0]
                            has_default = "=" in s.split("\n")[0]
                            stored.append((pname, has_default, is_let))
                if kind_tok == "struct" and not has_init:
                    params = [Param(p[0], p[1], False, False) for p in stored]
                    inits.setdefault(tname, []).append(Decl(tname, params, "%s:%d" % (rel, n.start_point[0] + 1), "memberwise"))
                    # `let x = 1` cannot be set through the initialiser
                    inits[tname][-1].params = [Param(p[0], p[1], False, False) for p in stored if not (p[2] and p[1])]
            elif n.type == "function_declaration":
                nm = n.child_by_field_name("name")
                if nm is None:
                    continue
                anc = n.parent
                nested = False
                while anc is not None:
                    if anc.type in ("function_body", "lambda_literal"):
                        nested = True
                        break
                    anc = anc.parent
                if nested:
                    continue          # local helper functions live in their own scope
                funcs.setdefault(txt(nm, src), []).append(Decl(txt(nm, src), parse_params(n, src), "%s:%d" % (rel, n.start_point[0] + 1), "func"))
            elif n.type == "protocol_function_declaration":
                nm = n.child_by_field_name("name")
                if nm is not None:
                    funcs.setdefault(txt(nm, src), []).append(Decl(txt(nm, src), parse_params(n, src), "%s:%d" % (rel, n.start_point[0] + 1), "func"))
    return funcs, inits, types


def call_args(call, src):
    """(labels list, n_trailing_closures) or None when it cannot be analysed"""
    suffix = None
    for c in call.children:
        if c.type == "call_suffix":
            suffix = c
    if suffix is None:
        return None
    labels = []
    trailing = 0
    for c in suffix.children:
        if c.type == "value_arguments":
            for a in c.children:
                if a.type == "value_argument":
                    lab = None
                    for x in a.children:
                        if x.type == "value_argument_label":
                            lab = txt(x, src)
                    labels.append(lab)
        elif c.type == "lambda_literal":
            trailing += 1
        elif c.type == "annotated_expression":
            trailing += 1
    return labels, trailing


def matches(decl, labels, trailing):
    params = decl.params
    pi = 0
    for lab in labels:
        matched = False
        while pi < len(params):
            p = params[pi]
            if p.label == lab:
                pi += 1
                matched = True
                if p.variadic:
                    pi -= 1      # variadic can take more; assume the next args also fit
                    # consume following unlabeled args
                break
            if p.default or p.variadic:
                pi += 1
                continue
            return False
        if not matched:
            return False
        if pi > 0 and params[pi - 1].variadic:
            pi += 1
    remaining = params[pi:]
    t = trailing
    for p in remaining:
        if p.default or p.variadic:
            continue
        if p.is_func and t > 0:
            t -= 1
            continue
        return False
    # trailing closures can also fill defaulted function params
    return True


def callee_name(call, src):
    first = call.children[0] if call.children else None
    if first is None:
        return None, False
    if first.type == "simple_identifier":
        return txt(first, src), False
    if first.type == "navigation_expression":
        suf = [c for c in first.children if c.type == "navigation_suffix"]
        if suf:
            ids = [c for c in suf[-1].children if c.type == "simple_identifier"]
            if ids:
                return txt(ids[-1], src), True
    return None, False


def main():
    files = {}
    for dp, dn, fn in os.walk(ROOT):
        for f in fn:
            if f.endswith(".swift"):
                p = os.path.join(dp, f)
                src = open(p, "rb").read()
                files[p] = (PARSER.parse(src), src)
    funcs, inits, types = collect(files)
    bad = 0
    checked = 0
    for f, (tree, src) in sorted(files.items()):
        rel = os.path.relpath(f, ROOT)
        for n in walk(tree.root_node):
            if n.type != "call_expression":
                continue
            name, is_member = callee_name(n, src)
            if name is None:
                continue
            ca = call_args(n, src)
            if ca is None:
                continue
            labels, trailing = ca
            cands = []
            if name in IGNORE and is_member:
                continue
            if name in inits and not is_member:
                cands += inits[name]
            if name in funcs:
                cands += funcs[name]
            if is_member and name in inits and name not in funcs:
                cands += []          # Type.init style calls are not analysed
            if not cands:
                continue
            checked += 1
            if any(matches(d, labels, trailing) for d in cands):
                continue
            bad += 1
            line = n.start_point[0] + 1
            print("CALL %s:%d  %s(%s)%s  no match among: %s" % (
                rel, line, name, ", ".join((l + ":") if l else "_" for l in labels), " +trailing" if trailing else "",
                "; ".join(d.sig() + "@" + d.where for d in cands[:4])))
    print("checked %d calls to project functions/initialisers, %d without a matching declaration" % (checked, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
