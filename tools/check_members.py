# -*- coding: utf-8 -*-
"""Lists member names (after a '.') that are used in the project but declared nowhere in the project - i.e. Apple / stdlib members.
Review the list by eye for typos.   python tools/check_members.py"""
import os, sys, collections
import tree_sitter_swift
from tree_sitter import Language, Parser
ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Supercars")
P = Parser(Language(tree_sitter_swift.language()))
def walk(n):
    st=[n]
    while st:
        x=st.pop(); yield x; st.extend(reversed(x.children))
def t(n,src): return src[n.start_byte:n.end_byte].decode('utf8','replace')
files={}
for dp,dn,fn in os.walk(ROOT):
    for f in fn:
        if f.endswith('.swift'):
            p=os.path.join(dp,f); s=open(p,'rb').read(); files[p]=(P.parse(s),s)
declared=set()
for p,(tree,src) in files.items():
    for n in walk(tree.root_node):
        if n.type in ('function_declaration','protocol_function_declaration'):
            nm=n.child_by_field_name('name')
            if nm is not None: declared.add(t(nm,src))
        elif n.type in ('property_declaration','protocol_property_declaration'):
            for x in walk(n):
                if x.type=='pattern': declared.add(t(x,src).strip()); break
        elif n.type=='enum_entry':
            for c in n.children:
                if c.type=='simple_identifier': declared.add(t(c,src))
        elif n.type=='class_declaration':
            nm=n.child_by_field_name('name')
            if nm is not None: declared.add(t(nm,src))
        elif n.type=='parameter':
            ids=[t(x,src) for x in n.children if x.type=='simple_identifier']
            declared.update(ids)
        elif n.type=='typealias_declaration':
            nm=n.child_by_field_name('name'); 
            if nm is not None: declared.add(t(nm,src))
        elif n.type=='lambda_parameter' or n.type=='lambda_function_type_parameters':
            pass
used=collections.defaultdict(list)
for p,(tree,src) in files.items():
    rel=os.path.relpath(p,ROOT)
    for n in walk(tree.root_node):
        if n.type=='navigation_suffix':
            ids=[c for c in n.children if c.type=='simple_identifier']
            if ids:
                nm=t(ids[-1],src)
                if nm not in declared: used[nm].append("%s:%d"%(rel,n.start_point[0]+1))
for nm,w in sorted(used.items()):
    print("%-28s x%-3d %s"%(nm,len(w),w[0]))
