//#region \0rolldown/runtime.js
var e = Object.create, t = Object.defineProperty, n = Object.getOwnPropertyDescriptor, r = Object.getOwnPropertyNames, i = Object.getPrototypeOf, a = Object.prototype.hasOwnProperty, o = (e, t) => () => (t || (e((t = { exports: {} }).exports, t), e = null), t.exports), s = (e, i, o, s) => {
	if (i && typeof i == "object" || typeof i == "function") for (var c = r(i), l = 0, u = c.length, d; l < u; l++) d = c[l], !a.call(e, d) && d !== o && t(e, d, {
		get: ((e) => i[e]).bind(null, d),
		enumerable: !(s = n(i, d)) || s.enumerable
	});
	return e;
}, c = (n, r, a) => (a = n == null ? {} : e(i(n)), s(r || !n || !n.__esModule ? t(a, "default", {
	value: n,
	enumerable: !0
}) : a, n)), l = {
	context: void 0,
	registry: void 0,
	effects: void 0,
	done: !1,
	getContextId() {
		return u(this.context.count);
	},
	getNextContextId() {
		return u(this.context.count++);
	}
};
function u(e) {
	let t = String(e), n = t.length - 1;
	return l.context.id + (n ? String.fromCharCode(96 + n) : "") + t;
}
function d(e) {
	l.context = e;
}
function f() {
	return {
		...l.context,
		id: l.getNextContextId(),
		count: 0
	};
}
var p = (e, t) => e === t, m = Symbol("solid-proxy"), h = typeof Proxy == "function", g = Symbol("solid-track"), _ = { equals: p }, v = null, y = Ce, b = 1, x = 2, ee = {
	owned: null,
	cleanups: null,
	context: null,
	owner: null
}, S = {}, C = null, w = null, T = null, E = null, D = null, O = null, k = null, te = 0;
function A(e, t) {
	let n = D, r = C, i = e.length === 0, a = t === void 0 ? r : t, o = i ? ee : {
		owned: null,
		cleanups: null,
		context: a ? a.context : null,
		owner: a
	}, s = i ? e : () => e(() => I(() => Oe(o)));
	C = o, D = null;
	try {
		return xe(s, !0);
	} finally {
		D = n, C = r;
	}
}
function j(e, t) {
	t = t ? Object.assign({}, _, t) : _;
	let n = {
		value: e,
		observers: null,
		observerSlots: null,
		comparator: t.equals || void 0
	};
	return [he.bind(n), (e) => (typeof e == "function" && (e = w && w.running && w.sources.has(n) ? e(n.tValue) : e(n.value)), ge(n, e))];
}
function M(e, t, n) {
	let r = ye(e, t, !0, b);
	T && w && w.running ? O.push(r) : _e(r);
}
function N(e, t, n) {
	let r = ye(e, t, !1, b);
	T && w && w.running ? O.push(r) : _e(r);
}
function P(e, t, n) {
	y = Te;
	let r = ye(e, t, !1, b), i = me && fe(me);
	i && (r.suspense = i), (!n || !n.render) && (r.user = !0), k ? k.push(r) : _e(r);
}
function F(e, t, n) {
	n = n ? Object.assign({}, _, n) : _;
	let r = ye(e, t, !0, 0);
	return r.observers = null, r.observerSlots = null, r.comparator = n.equals || void 0, T && w && w.running ? (r.tState = b, O.push(r)) : _e(r), he.bind(r);
}
function ne(e) {
	return e && typeof e == "object" && "then" in e;
}
function re(e, t, n) {
	let r, i, a;
	typeof t == "function" ? (r = e, i = t, a = n || {}) : (r = !0, i = e, a = t || {});
	let o = null, s = S, c = null, u = !1, d = !1, f = "initialValue" in a, p = typeof r == "function" && F(r), m = /* @__PURE__ */ new Set(), [h, g] = (a.storage || j)(a.initialValue), [_, v] = j(void 0), [y, b] = j(void 0, { equals: !1 }), [x, ee] = j(f ? "ready" : "unresolved");
	l.context && (c = l.getNextContextId(), a.ssrLoadFrom === "initial" ? s = a.initialValue : l.load && l.has(c) && (s = l.load(c)));
	function T(e, t, n, r) {
		return o === e && (o = null, r !== void 0 && (f = !0), (e === s || t === s) && a.onHydrated && queueMicrotask(() => a.onHydrated(r, { value: t })), s = S, w && e && u ? (w.promises.delete(e), u = !1, xe(() => {
			w.running = !0, E(t, n);
		}, !1)) : E(t, n)), t;
	}
	function E(e, t) {
		xe(() => {
			t === void 0 && g(() => e), ee(t === void 0 ? f ? "ready" : "unresolved" : "errored"), v(t);
			for (let e of m.keys()) e.decrement();
			m.clear();
		}, !1);
	}
	function O() {
		let e = me && fe(me), t = h(), n = _();
		if (n !== void 0 && !o) throw n;
		return D && !D.user && e && M(() => {
			y(), o && (e.resolved && w && u ? w.promises.add(o) : m.has(e) || (e.increment(), m.add(e)));
		}), t;
	}
	function k(e = !0) {
		if (e !== !1 && d) return;
		d = !1;
		let t = p ? p() : r;
		if (u = w && w.running, t == null || t === !1) {
			T(o, I(h));
			return;
		}
		w && o && w.promises.delete(o);
		let n, a = s === S ? I(() => {
			try {
				return i(t, {
					value: h(),
					refetching: e
				});
			} catch (e) {
				n = e;
			}
		}) : s;
		if (n !== void 0) {
			T(o, void 0, Ae(n), t);
			return;
		} else if (!ne(a)) return T(o, a, void 0, t), a;
		return o = a, "v" in a ? (a.s === 1 ? T(o, a.v, void 0, t) : T(o, void 0, Ae(a.v), t), a) : (d = !0, queueMicrotask(() => d = !1), xe(() => {
			ee(f ? "refreshing" : "pending"), b();
		}, !1), a.then((e) => T(a, e, void 0, t), (e) => T(a, void 0, Ae(e), t)));
	}
	Object.defineProperties(O, {
		state: { get: () => x() },
		error: { get: () => _() },
		loading: { get() {
			let e = x();
			return e === "pending" || e === "refreshing";
		} },
		latest: { get() {
			if (!f) return O();
			let e = _();
			if (e && !o) throw e;
			return h();
		} }
	});
	let te = C;
	return p ? M(() => (te = C, k(!1))) : k(!1), [O, {
		refetch: (e) => se(te, () => k(e)),
		mutate: g
	}];
}
function I(e) {
	if (!E && D === null) return e();
	let t = D;
	D = null;
	try {
		return E ? E.untrack(e) : e();
	} finally {
		D = t;
	}
}
function ie(e, t, n) {
	let r = Array.isArray(e), i, a = n && n.defer;
	return (n) => {
		let o;
		if (r) {
			o = Array(e.length);
			for (let t = 0; t < e.length; t++) o[t] = e[t]();
		} else o = e();
		if (a) return a = !1, n;
		let s = I(() => t(o, i, n));
		return i = o, s;
	};
}
function ae(e) {
	P(() => I(e));
}
function L(e) {
	return C === null || (C.cleanups === null ? C.cleanups = [e] : C.cleanups.push(e)), e;
}
function oe() {
	return C;
}
function se(e, t) {
	let n = C, r = D;
	C = e, D = null;
	try {
		return xe(t, !0);
	} catch (e) {
		Me(e);
	} finally {
		C = n, D = r;
	}
}
function ce(e) {
	if (w && w.running) return e(), w.done;
	let t = D, n = C;
	return Promise.resolve().then(() => {
		D = t, C = n;
		let r;
		return (T || me) && (r = w ||= {
			sources: /* @__PURE__ */ new Set(),
			effects: [],
			promises: /* @__PURE__ */ new Set(),
			disposed: /* @__PURE__ */ new Set(),
			queue: /* @__PURE__ */ new Set(),
			running: !0
		}, r.done ||= new Promise((e) => r.resolve = e), r.running = !0), xe(e, !1), D = C = null, r ? r.done : void 0;
	});
}
var [le, ue] = /*@__PURE__*/ j(!1);
function de(e, t) {
	let n = Symbol("context");
	return {
		id: n,
		Provider: Pe(n),
		defaultValue: e
	};
}
function fe(e) {
	let t;
	return C && C.context && (t = C.context[e.id]) !== void 0 ? t : e.defaultValue;
}
function pe(e) {
	let t = F(e), n = F(() => Ne(t()));
	return n.toArray = () => {
		let e = n();
		return Array.isArray(e) ? e : e == null ? [] : [e];
	}, n;
}
var me;
function he() {
	let e = w && w.running;
	if (this.sources && (e ? this.tState : this.state)) if ((e ? this.tState : this.state) === b) _e(this);
	else {
		let e = O;
		O = null, xe(() => Ee(this), !1), O = e;
	}
	if (D) {
		let e = this.observers;
		if (!e || e[e.length - 1] !== D) {
			let t = e ? e.length : 0;
			D.sources ? (D.sources.push(this), D.sourceSlots.push(t)) : (D.sources = [this], D.sourceSlots = [t]), e ? (e.push(D), this.observerSlots.push(D.sources.length - 1)) : (this.observers = [D], this.observerSlots = [D.sources.length - 1]);
		}
	}
	return e && w.sources.has(this) ? this.tValue : this.value;
}
function ge(e, t, n) {
	let r = w && w.running && w.sources.has(e) ? e.tValue : e.value;
	if (!e.comparator || !e.comparator(r, t)) {
		if (w) {
			let r = w.running;
			(r || !n && w.sources.has(e)) && (w.sources.add(e), e.tValue = t), r || (e.value = t);
		} else e.value = t;
		e.observers && e.observers.length && xe(() => {
			for (let t = 0; t < e.observers.length; t += 1) {
				let n = e.observers[t], r = w && w.running;
				r && w.disposed.has(n) || ((r ? !n.tState : !n.state) && (n.pure ? O.push(n) : k.push(n), n.observers && De(n)), r ? n.tState = b : n.state = b);
			}
			if (O.length > 1e6) throw O = [], Error();
		}, !1);
	}
	return t;
}
function _e(e) {
	if (!e.fn) return;
	Oe(e);
	let t = te;
	ve(e, w && w.running && w.sources.has(e) ? e.tValue : e.value, t), w && !w.running && w.sources.has(e) && queueMicrotask(() => {
		xe(() => {
			w && (w.running = !0), D = C = e, ve(e, e.tValue, t), D = C = null;
		}, !1);
	});
}
function ve(e, t, n) {
	let r, i = C, a = D;
	D = C = e;
	try {
		r = e.fn(t);
	} catch (t) {
		return e.pure && (w && w.running ? (e.tState = b, e.tOwned && e.tOwned.forEach(Oe), e.tOwned = void 0) : (e.state = b, e.owned && e.owned.forEach(Oe), e.owned = null)), e.updatedAt = n + 1, Me(t);
	} finally {
		D = a, C = i;
	}
	(!e.updatedAt || e.updatedAt <= n) && (e.updatedAt != null && "observers" in e ? ge(e, r, !0) : w && w.running && e.pure ? (w.sources.has(e) || (e.value = r), w.sources.add(e), e.tValue = r) : e.value = r, e.updatedAt = n);
}
function ye(e, t, n, r = b, i) {
	let a = {
		fn: e,
		state: r,
		updatedAt: null,
		owned: null,
		sources: null,
		sourceSlots: null,
		cleanups: null,
		value: t,
		owner: C,
		context: C ? C.context : null,
		pure: n
	};
	if (w && w.running && (a.state = 0, a.tState = r), C === null || C !== ee && (w && w.running && C.pure ? C.tOwned ? C.tOwned.push(a) : C.tOwned = [a] : C.owned ? C.owned.push(a) : C.owned = [a]), E && a.fn) {
		let e = a.fn, [t, n] = j(void 0, { equals: !1 }), r = E.factory(e, n);
		L(() => r.dispose());
		let i, o = () => ce(n).then(() => {
			i &&= (i.dispose(), void 0);
		});
		a.fn = (n) => (t(), w && w.running ? (i ||= E.factory(e, o), i.track(n)) : r.track(n));
	}
	return a;
}
function be(e) {
	let t = w && w.running;
	if ((t ? e.tState : e.state) === 0) return;
	if ((t ? e.tState : e.state) === x) return Ee(e);
	if (e.suspense && I(e.suspense.inFallback)) return e.suspense.effects.push(e);
	let n = [e];
	for (; (e = e.owner) && (!e.updatedAt || e.updatedAt < te);) {
		if (t && w.disposed.has(e)) return;
		(t ? e.tState : e.state) && n.push(e);
	}
	for (let r = n.length - 1; r >= 0; r--) {
		if (e = n[r], t) {
			let t = e, i = n[r + 1];
			for (; (t = t.owner) && t !== i;) if (w.disposed.has(t)) return;
		}
		if ((t ? e.tState : e.state) === b) _e(e);
		else if ((t ? e.tState : e.state) === x) {
			let t = O;
			O = null, xe(() => Ee(e, n[0]), !1), O = t;
		}
	}
}
function xe(e, t) {
	if (O) return e();
	let n = !1;
	t || (O = []), k ? n = !0 : k = [], te++;
	try {
		let t = e();
		return Se(n), t;
	} catch (e) {
		n || (k = null), O = null, Me(e);
	}
}
function Se(e) {
	if (O &&= (T && w && w.running ? we(O) : Ce(O), null), e) return;
	let t;
	if (w) {
		if (!w.promises.size && !w.queue.size) {
			let e = w.sources, n = w.disposed;
			k.push.apply(k, w.effects), t = w.resolve;
			for (let e of k) "tState" in e && (e.state = e.tState), delete e.tState;
			w = null, xe(() => {
				for (let e of n) Oe(e);
				for (let t of e) {
					if (t.value = t.tValue, t.owned) for (let e = 0, n = t.owned.length; e < n; e++) Oe(t.owned[e]);
					t.tOwned && (t.owned = t.tOwned), delete t.tValue, delete t.tOwned, t.tState = 0;
				}
				ue(!1);
			}, !1);
		} else if (w.running) {
			w.running = !1, w.effects.push.apply(w.effects, k), k = null, ue(!0);
			return;
		}
	}
	let n = k;
	k = null, n.length && xe(() => y(n), !1), t && t();
}
function Ce(e) {
	for (let t = 0; t < e.length; t++) be(e[t]);
}
function we(e) {
	for (let t = 0; t < e.length; t++) {
		let n = e[t], r = w.queue;
		r.has(n) || (r.add(n), T(() => {
			r.delete(n), xe(() => {
				w.running = !0, be(n);
			}, !1), w && (w.running = !1);
		}));
	}
}
function Te(e) {
	let t, n = 0;
	for (t = 0; t < e.length; t++) {
		let r = e[t];
		r.user ? e[n++] = r : be(r);
	}
	if (l.context) {
		if (l.count) {
			l.effects ||= [], l.effects.push(...e.slice(0, n));
			return;
		}
		d();
	}
	for (l.effects && (l.done || !l.count) && (e = [...l.effects, ...e], n += l.effects.length, delete l.effects), t = 0; t < n; t++) be(e[t]);
}
function Ee(e, t) {
	let n = w && w.running;
	n ? e.tState = 0 : e.state = 0;
	for (let r = 0; r < e.sources.length; r += 1) {
		let i = e.sources[r];
		if (i.sources) {
			let e = n ? i.tState : i.state;
			e === b ? i !== t && (!i.updatedAt || i.updatedAt < te) && be(i) : e === x && Ee(i, t);
		}
	}
}
function De(e) {
	let t = w && w.running;
	for (let n = 0; n < e.observers.length; n += 1) {
		let r = e.observers[n];
		(t ? !r.tState : !r.state) && (t ? r.tState = x : r.state = x, r.pure ? O.push(r) : k.push(r), r.observers && De(r));
	}
}
function Oe(e) {
	let t;
	if (e.sources) for (; e.sources.length;) {
		let t = e.sources.pop(), n = e.sourceSlots.pop(), r = t.observers;
		if (r && r.length) {
			let e = r.pop(), i = t.observerSlots.pop();
			n < r.length && (e.sourceSlots[i] = n, r[n] = e, t.observerSlots[n] = i);
		}
	}
	if (e.tOwned) {
		for (t = e.tOwned.length - 1; t >= 0; t--) Oe(e.tOwned[t]);
		delete e.tOwned;
	}
	if (w && w.running && e.pure) ke(e, !0);
	else if (e.owned) {
		for (t = e.owned.length - 1; t >= 0; t--) Oe(e.owned[t]);
		e.owned = null;
	}
	if (e.cleanups) {
		for (t = e.cleanups.length - 1; t >= 0; t--) e.cleanups[t]();
		e.cleanups = null;
	}
	w && w.running ? e.tState = 0 : e.state = 0;
}
function ke(e, t) {
	if (t || (e.tState = 0, w.disposed.add(e)), e.owned) for (let t = 0; t < e.owned.length; t++) ke(e.owned[t]);
}
function Ae(e) {
	return e instanceof Error ? e : Error(typeof e == "string" ? e : "Unknown error", { cause: e });
}
function je(e, t, n) {
	try {
		for (let n of t) n(e);
	} catch (e) {
		Me(e, n && n.owner || null);
	}
}
function Me(e, t = C) {
	let n = v && t && t.context && t.context[v], r = Ae(e);
	if (!n) throw r;
	k ? k.push({
		fn() {
			je(r, n, t);
		},
		state: b
	}) : je(r, n, t);
}
function Ne(e) {
	if (typeof e == "function" && !e.length) return Ne(e());
	if (Array.isArray(e)) {
		let t = [];
		for (let n = 0; n < e.length; n++) {
			let r = Ne(e[n]);
			if (Array.isArray(r)) if (r.length < 32768) t.push.apply(t, r);
			else for (let e = 0; e < r.length; e++) t.push(r[e]);
			else t.push(r);
		}
		return t;
	}
	return e;
}
function Pe(e, t) {
	return function(t) {
		let n;
		return N(() => n = I(() => (C.context = {
			...C.context,
			[e]: t.value
		}, pe(() => t.children))), void 0), n;
	};
}
var Fe = Symbol("fallback");
function Ie(e) {
	for (let t = 0; t < e.length; t++) e[t]();
}
function Le(e, t, n = {}) {
	let r = [], i = [], a = [], o = 0, s = t.length > 1 ? [] : null;
	return L(() => Ie(a)), () => {
		let c = e() || [], l = c.length, u, d;
		return c[g], I(() => {
			let e, t, p, m, h, g, _, v, y;
			if (l === 0) o !== 0 && (Ie(a), a = [], r = [], i = [], o = 0, s &&= []), n.fallback && (r = [Fe], i[0] = A((e) => (a[0] = e, n.fallback())), o = 1);
			else if (o === 0) {
				for (i = Array(l), d = 0; d < l; d++) r[d] = c[d], i[d] = A(f);
				o = l;
			} else {
				for (p = Array(l), m = Array(l), s && (h = Array(l)), g = 0, _ = Math.min(o, l); g < _ && r[g] === c[g]; g++);
				for (_ = o - 1, v = l - 1; _ >= g && v >= g && r[_] === c[v]; _--, v--) p[v] = i[_], m[v] = a[_], s && (h[v] = s[_]);
				for (e = /* @__PURE__ */ new Map(), t = Array(v + 1), d = v; d >= g; d--) y = c[d], u = e.get(y), t[d] = u === void 0 ? -1 : u, e.set(y, d);
				for (u = g; u <= _; u++) y = r[u], d = e.get(y), d !== void 0 && d !== -1 ? (p[d] = i[u], m[d] = a[u], s && (h[d] = s[u]), d = t[d], e.set(y, d)) : a[u]();
				for (d = g; d < l; d++) d in p ? (i[d] = p[d], a[d] = m[d], s && (s[d] = h[d], s[d](d))) : i[d] = A(f);
				i = i.slice(0, o = l), r = c.slice(0);
			}
			return i;
		});
		function f(e) {
			if (a[d] = e, s) {
				let [e, n] = j(d);
				return s[d] = n, t(c[d], e);
			}
			return t(c[d]);
		}
	};
}
var Re = !1;
function R(e, t) {
	if (Re && l.context) {
		let n = l.context;
		d(f());
		let r = I(() => e(t || {}));
		return d(n), r;
	}
	return I(() => e(t || {}));
}
function ze() {
	return !0;
}
var Be = {
	get(e, t, n) {
		return t === m ? n : e.get(t);
	},
	has(e, t) {
		return t === m ? !0 : e.has(t);
	},
	set: ze,
	deleteProperty: ze,
	getOwnPropertyDescriptor(e, t) {
		return {
			configurable: !0,
			enumerable: !0,
			get() {
				return e.get(t);
			},
			set: ze,
			deleteProperty: ze
		};
	},
	ownKeys(e) {
		return e.keys();
	}
};
function Ve(e) {
	return (e = typeof e == "function" ? e() : e) ? e : {};
}
function He() {
	for (let e = 0, t = this.length; e < t; ++e) {
		let t = this[e]();
		if (t !== void 0) return t;
	}
}
function z(...e) {
	let t = !1;
	for (let n = 0; n < e.length; n++) {
		let r = e[n];
		t ||= !!r && m in r, e[n] = typeof r == "function" ? (t = !0, F(r)) : r;
	}
	if (h && t) return new Proxy({
		get(t) {
			for (let n = e.length - 1; n >= 0; n--) {
				let r = Ve(e[n])[t];
				if (r !== void 0) return r;
			}
		},
		has(t) {
			for (let n = e.length - 1; n >= 0; n--) if (t in Ve(e[n])) return !0;
			return !1;
		},
		keys() {
			let t = [];
			for (let n = 0; n < e.length; n++) t.push(...Object.keys(Ve(e[n])));
			return [...new Set(t)];
		}
	}, Be);
	let n = {}, r = Object.create(null);
	for (let t = e.length - 1; t >= 0; t--) {
		let i = e[t];
		if (!i) continue;
		let a = Object.getOwnPropertyNames(i);
		for (let e = a.length - 1; e >= 0; e--) {
			let t = a[e];
			if (t === "__proto__" || t === "constructor") continue;
			let o = Object.getOwnPropertyDescriptor(i, t);
			if (!r[t]) r[t] = o.get ? {
				enumerable: !0,
				configurable: !0,
				get: He.bind(n[t] = [o.get.bind(i)])
			} : o.value === void 0 ? void 0 : o;
			else {
				let e = n[t];
				e && (o.get ? e.push(o.get.bind(i)) : o.value !== void 0 && e.push(() => o.value));
			}
		}
	}
	let i = {}, a = Object.keys(r);
	for (let e = a.length - 1; e >= 0; e--) {
		let t = a[e], n = r[t];
		n && n.get ? Object.defineProperty(i, t, n) : i[t] = n ? n.value : void 0;
	}
	return i;
}
function B(e, ...t) {
	let n = t.length;
	if (h && m in e) {
		let r = n > 1 ? t.flat() : t[0], i = t.map((t) => new Proxy({
			get(n) {
				return t.includes(n) ? e[n] : void 0;
			},
			has(n) {
				return t.includes(n) && n in e;
			},
			keys() {
				return t.filter((t) => t in e);
			}
		}, Be));
		return i.push(new Proxy({
			get(t) {
				return r.includes(t) ? void 0 : e[t];
			},
			has(t) {
				return r.includes(t) ? !1 : t in e;
			},
			keys() {
				return Object.keys(e).filter((e) => !r.includes(e));
			}
		}, Be)), i;
	}
	let r = [];
	for (let e = 0; e <= n; e++) r[e] = {};
	for (let i of Object.getOwnPropertyNames(e)) {
		let a = n;
		for (let e = 0; e < t.length; e++) if (t[e].includes(i)) {
			a = e;
			break;
		}
		let o = Object.getOwnPropertyDescriptor(e, i);
		!o.get && !o.set && o.enumerable && o.writable && o.configurable ? r[a][i] = o.value : Object.defineProperty(r[a], i, o);
	}
	return r;
}
var Ue = 0;
function We() {
	return l.context ? l.getNextContextId() : `cl-${Ue++}`;
}
var Ge = (e) => `Stale read from <${e}>.`;
function V(e) {
	let t = "fallback" in e && { fallback: () => e.fallback };
	return F(Le(() => e.each, e.children, t || void 0));
}
function H(e) {
	let t = e.keyed, n = F(() => e.when, void 0, void 0), r = t ? n : F(n, void 0, { equals: (e, t) => !e == !t });
	return F(() => {
		let i = r();
		if (i) {
			let a = e.children;
			return typeof a == "function" && a.length > 0 ? I(() => a(t ? i : () => {
				if (!I(r)) throw Ge("Show");
				return n();
			})) : a;
		}
		return e.fallback;
	}, void 0, void 0);
}
function Ke(e) {
	let t = pe(() => e.children), n = F(() => {
		let e = t(), n = Array.isArray(e) ? e : [e], r = () => void 0;
		for (let e = 0; e < n.length; e++) {
			let t = e, i = n[e], a = r, o = F(() => a() ? void 0 : i.when, void 0, void 0), s = i.keyed ? o : F(o, void 0, { equals: (e, t) => !e == !t });
			r = () => a() || (s() ? [
				t,
				o,
				i
			] : void 0);
		}
		return r;
	});
	return F(() => {
		let t = n()();
		if (!t) return e.fallback;
		let [r, i, a] = t, o = a.children;
		return typeof o == "function" && o.length > 0 ? I(() => o(a.keyed ? i() : () => {
			if (I(n)()?.[0] !== r) throw Ge("Match");
			return i();
		})) : o;
	}, void 0, void 0);
}
function qe(e) {
	return e;
}
//#endregion
//#region node_modules/.pnpm/solid-js@1.9.13/node_modules/solid-js/web/dist/web.js
var Je = /*#__PURE__*/ new Set([
	"className",
	"value",
	"readOnly",
	"noValidate",
	"formNoValidate",
	"isMap",
	"noModule",
	"playsInline",
	"adAuctionHeaders",
	"allowFullscreen",
	"browsingTopics",
	"defaultChecked",
	"defaultMuted",
	"defaultSelected",
	"disablePictureInPicture",
	"disableRemotePlayback",
	"preservesPitch",
	"shadowRootClonable",
	"shadowRootCustomElementRegistry",
	"shadowRootDelegatesFocus",
	"shadowRootSerializable",
	"sharedStorageWritable",
	.../* @__PURE__ */ "allowfullscreen.async.alpha.autofocus.autoplay.checked.controls.default.disabled.formnovalidate.hidden.indeterminate.inert.ismap.loop.multiple.muted.nomodule.novalidate.open.playsinline.readonly.required.reversed.seamless.selected.adauctionheaders.browsingtopics.credentialless.defaultchecked.defaultmuted.defaultselected.defer.disablepictureinpicture.disableremoteplayback.preservespitch.shadowrootclonable.shadowrootcustomelementregistry.shadowrootdelegatesfocus.shadowrootserializable.sharedstoragewritable".split(".")
]), Ye = /*#__PURE__*/ new Set([
	"innerHTML",
	"textContent",
	"innerText",
	"children"
]), Xe = /*#__PURE__*/ Object.assign(Object.create(null), {
	className: "class",
	htmlFor: "for"
}), Ze = /*#__PURE__*/ Object.assign(Object.create(null), {
	class: "className",
	novalidate: {
		$: "noValidate",
		FORM: 1
	},
	formnovalidate: {
		$: "formNoValidate",
		BUTTON: 1,
		INPUT: 1
	},
	ismap: {
		$: "isMap",
		IMG: 1
	},
	nomodule: {
		$: "noModule",
		SCRIPT: 1
	},
	playsinline: {
		$: "playsInline",
		VIDEO: 1
	},
	readonly: {
		$: "readOnly",
		INPUT: 1,
		TEXTAREA: 1
	},
	adauctionheaders: {
		$: "adAuctionHeaders",
		IFRAME: 1
	},
	allowfullscreen: {
		$: "allowFullscreen",
		IFRAME: 1
	},
	browsingtopics: {
		$: "browsingTopics",
		IMG: 1
	},
	defaultchecked: {
		$: "defaultChecked",
		INPUT: 1
	},
	defaultmuted: {
		$: "defaultMuted",
		AUDIO: 1,
		VIDEO: 1
	},
	defaultselected: {
		$: "defaultSelected",
		OPTION: 1
	},
	disablepictureinpicture: {
		$: "disablePictureInPicture",
		VIDEO: 1
	},
	disableremoteplayback: {
		$: "disableRemotePlayback",
		AUDIO: 1,
		VIDEO: 1
	},
	preservespitch: {
		$: "preservesPitch",
		AUDIO: 1,
		VIDEO: 1
	},
	shadowrootclonable: {
		$: "shadowRootClonable",
		TEMPLATE: 1
	},
	shadowrootdelegatesfocus: {
		$: "shadowRootDelegatesFocus",
		TEMPLATE: 1
	},
	shadowrootserializable: {
		$: "shadowRootSerializable",
		TEMPLATE: 1
	},
	sharedstoragewritable: {
		$: "sharedStorageWritable",
		IFRAME: 1,
		IMG: 1
	}
});
function Qe(e, t) {
	let n = Ze[e];
	return typeof n == "object" ? n[t] ? n.$ : void 0 : n;
}
var $e = /*#__PURE__*/ new Set([
	"beforeinput",
	"click",
	"dblclick",
	"contextmenu",
	"focusin",
	"focusout",
	"input",
	"keydown",
	"keyup",
	"mousedown",
	"mousemove",
	"mouseout",
	"mouseover",
	"mouseup",
	"pointerdown",
	"pointermove",
	"pointerout",
	"pointerover",
	"pointerup",
	"touchend",
	"touchmove",
	"touchstart"
]), et = /*#__PURE__*/ new Set(/* @__PURE__ */ "altGlyph.altGlyphDef.altGlyphItem.animate.animateColor.animateMotion.animateTransform.circle.clipPath.color-profile.cursor.defs.desc.ellipse.feBlend.feColorMatrix.feComponentTransfer.feComposite.feConvolveMatrix.feDiffuseLighting.feDisplacementMap.feDistantLight.feDropShadow.feFlood.feFuncA.feFuncB.feFuncG.feFuncR.feGaussianBlur.feImage.feMerge.feMergeNode.feMorphology.feOffset.fePointLight.feSpecularLighting.feSpotLight.feTile.feTurbulence.filter.font.font-face.font-face-format.font-face-name.font-face-src.font-face-uri.foreignObject.g.glyph.glyphRef.hkern.image.line.linearGradient.marker.mask.metadata.missing-glyph.mpath.path.pattern.polygon.polyline.radialGradient.rect.set.stop.svg.switch.symbol.text.textPath.tref.tspan.use.view.vkern".split(".")), tt = {
	xlink: "http://www.w3.org/1999/xlink",
	xml: "http://www.w3.org/XML/1998/namespace"
}, U = (e) => F(() => e());
function nt(e, t, n) {
	let r = n.length, i = t.length, a = r, o = 0, s = 0, c = t[i - 1].nextSibling, l = null;
	for (; o < i || s < a;) {
		if (t[o] === n[s]) {
			o++, s++;
			continue;
		}
		for (; t[i - 1] === n[a - 1];) i--, a--;
		if (i === o) {
			let t = a < r ? s ? n[s - 1].nextSibling : n[a - s] : c;
			for (; s < a;) e.insertBefore(n[s++], t);
		} else if (a === s) for (; o < i;) (!l || !l.has(t[o])) && t[o].remove(), o++;
		else if (t[o] === n[a - 1] && n[s] === t[i - 1]) {
			let r = t[--i].nextSibling;
			e.insertBefore(n[s++], t[o++].nextSibling), e.insertBefore(n[--a], r), t[i] = n[a];
		} else {
			if (!l) {
				l = /* @__PURE__ */ new Map();
				let e = s;
				for (; e < a;) l.set(n[e], e++);
			}
			let r = l.get(t[o]);
			if (r != null) if (s < r && r < a) {
				let c = o, u = 1, d;
				for (; ++c < i && c < a && !((d = l.get(t[c])) == null || d !== r + u);) u++;
				if (u > r - s) {
					let i = t[o];
					for (; s < r;) e.insertBefore(n[s++], i);
				} else e.replaceChild(n[s++], t[o++]);
			} else o++;
			else t[o++].remove();
		}
	}
}
var rt = "_$DX_DELEGATE";
function it(e, t, n, r = {}) {
	let i;
	return A((r) => {
		i = r, t === document ? e() : X(t, e(), t.firstChild ? null : void 0, n);
	}, r.owner), () => {
		i(), t.textContent = "";
	};
}
function W(e, t, n, r) {
	let i, a = () => {
		let t = r ? document.createElementNS("http://www.w3.org/1998/Math/MathML", "template") : document.createElement("template");
		return t.innerHTML = e, n ? t.content.firstChild.firstChild : r ? t.firstChild : t.content.firstChild;
	}, o = t ? () => I(() => document.importNode(i ||= a(), !0)) : () => (i ||= a()).cloneNode(!0);
	return o.cloneNode = o, o;
}
function G(e, t = window.document) {
	let n = t[rt] || (t[rt] = /* @__PURE__ */ new Set());
	for (let r = 0, i = e.length; r < i; r++) {
		let i = e[r];
		n.has(i) || (n.add(i), t.addEventListener(i, _t));
	}
}
function K(e, t, n) {
	pt(e) || (n == null ? e.removeAttribute(t) : e.setAttribute(t, n));
}
function at(e, t, n, r) {
	pt(e) || (r == null ? e.removeAttributeNS(t, n) : e.setAttributeNS(t, n, r));
}
function ot(e, t, n) {
	pt(e) || (n ? e.setAttribute(t, "") : e.removeAttribute(t));
}
function q(e, t) {
	pt(e) || (t == null ? e.removeAttribute("class") : e.className = t);
}
function J(e, t, n, r) {
	if (r) Array.isArray(n) ? (e[`$$${t}`] = n[0], e[`$$${t}Data`] = n[1]) : e[`$$${t}`] = n;
	else if (Array.isArray(n)) {
		let r = n[0];
		e.addEventListener(t, n[0] = (t) => r.call(e, n[1], t));
	} else e.addEventListener(t, n, typeof n != "function" && n);
}
function st(e, t, n = {}) {
	let r = Object.keys(t || {}), i = Object.keys(n), a, o;
	for (a = 0, o = i.length; a < o; a++) {
		let r = i[a];
		!r || r === "undefined" || t[r] || (ht(e, r, !1), delete n[r]);
	}
	for (a = 0, o = r.length; a < o; a++) {
		let i = r[a], o = !!t[i];
		!i || i === "undefined" || n[i] === o || !o || (ht(e, i, !0), n[i] = o);
	}
	return n;
}
function ct(e, t, n) {
	if (!t) return n ? K(e, "style") : t;
	let r = e.style;
	if (typeof t == "string") return r.cssText = t;
	typeof n == "string" && (r.cssText = n = void 0), n ||= {}, t ||= {};
	let i, a;
	for (a in n) t[a] ?? r.removeProperty(a), delete n[a];
	for (a in t) i = t[a], i !== n[a] && (r.setProperty(a, i), n[a] = i);
	return n;
}
function Y(e, t, n) {
	n == null ? e.style.removeProperty(t) : e.style.setProperty(t, n);
}
function lt(e, t = {}, n, r) {
	let i = {};
	return r || N(() => i.children = vt(e, t.children, i.children)), N(() => typeof t.ref == "function" && ut(t.ref, e)), N(() => dt(e, t, n, !0, i, !0)), i;
}
function ut(e, t, n) {
	return I(() => e(t, n));
}
function X(e, t, n, r) {
	if (n !== void 0 && !r && (r = []), typeof t != "function") return vt(e, t, r, n);
	N((r) => vt(e, t(), r, n), r);
}
function dt(e, t, n, r, i = {}, a = !1) {
	t ||= {};
	for (let r in i) if (!(r in t)) {
		if (r === "children") continue;
		i[r] = gt(e, r, null, i[r], n, a, t);
	}
	for (let o in t) {
		if (o === "children") {
			r || vt(e, t.children);
			continue;
		}
		let s = t[o];
		i[o] = gt(e, o, s, i[o], n, a, t);
	}
}
function ft(e) {
	let t, n;
	return !pt() || !(t = l.registry.get(n = St())) ? e() : (l.completed && l.completed.add(t), l.registry.delete(n), t);
}
function pt(e) {
	return !!l.context && !l.done && (!e || e.isConnected);
}
function mt(e) {
	return e.toLowerCase().replace(/-([a-z])/g, (e, t) => t.toUpperCase());
}
function ht(e, t, n) {
	let r = t.trim().split(/\s+/);
	for (let t = 0, i = r.length; t < i; t++) e.classList.toggle(r[t], n);
}
function gt(e, t, n, r, i, a, o) {
	let s, c, l, u, d;
	if (t === "style") return ct(e, n, r);
	if (t === "classList") return st(e, n, r);
	if (n === r) return r;
	if (t === "ref") a || n(e);
	else if (t.slice(0, 3) === "on:") {
		let i = t.slice(3);
		r && e.removeEventListener(i, r, typeof r != "function" && r), n && e.addEventListener(i, n, typeof n != "function" && n);
	} else if (t.slice(0, 10) === "oncapture:") {
		let i = t.slice(10);
		r && e.removeEventListener(i, r, !0), n && e.addEventListener(i, n, !0);
	} else if (t.slice(0, 2) === "on") {
		let i = t.slice(2).toLowerCase(), a = $e.has(i);
		if (!a && r) {
			let t = Array.isArray(r) ? r[0] : r;
			e.removeEventListener(i, t);
		}
		(a || n) && (J(e, i, n, a), a && G([i]));
	} else if (t.slice(0, 5) === "attr:") K(e, t.slice(5), n);
	else if (t.slice(0, 5) === "bool:") ot(e, t.slice(5), n);
	else if ((d = t.slice(0, 5) === "prop:") || (l = Ye.has(t)) || !i && ((u = Qe(t, e.tagName)) || (c = Je.has(t))) || (s = e.nodeName.includes("-") || "is" in o)) {
		if (d) t = t.slice(5), c = !0;
		else if (pt(e)) return n;
		t === "class" || t === "className" ? q(e, n) : s && !c && !l ? e[mt(t)] = n : e[u || t] = n;
	} else {
		let r = i && t.indexOf(":") > -1 && tt[t.split(":")[0]];
		r ? at(e, r, t, n) : K(e, Xe[t] || t, n);
	}
	return n;
}
function _t(e) {
	if (l.registry && l.events && l.events.find(([t, n]) => n === e)) return;
	let t = e.target, n = `$$${e.type}`, r = e.target, i = e.currentTarget, a = (t) => Object.defineProperty(e, "target", {
		configurable: !0,
		value: t
	}), o = () => {
		let r = t[n];
		if (r && !t.disabled) {
			let i = t[`${n}Data`];
			if (i === void 0 ? r.call(t, e) : r.call(t, i, e), e.cancelBubble) return;
		}
		return t.host && typeof t.host != "string" && !t.host._$host && t.contains(e.target) && a(t.host), !0;
	}, s = () => {
		for (; o() && (t = t._$host || t.parentNode || t.host););
	};
	if (Object.defineProperty(e, "currentTarget", {
		configurable: !0,
		get() {
			return t || document;
		}
	}), l.registry && !l.done && (l.done = _$HY.done = !0), e.composedPath) {
		let n = e.composedPath();
		a(n[0]);
		for (let e = 0; e < n.length - 2 && (t = n[e], o()); e++) {
			if (t._$host) {
				t = t._$host, s();
				break;
			}
			if (t.parentNode === i) break;
		}
	} else s();
	a(r);
}
function vt(e, t, n, r, i) {
	let a = pt(e);
	if (a) {
		!n && (n = [...e.childNodes]);
		let t = [];
		for (let e = 0; e < n.length; e++) {
			let r = n[e];
			r.nodeType === 8 && r.data.slice(0, 2) === "!$" ? r.remove() : t.push(r);
		}
		n = t;
	}
	for (; typeof n == "function";) n = n();
	if (t === n) return n;
	let o = typeof t, s = r !== void 0;
	if (e = s && n[0] && n[0].parentNode || e, o === "string" || o === "number") {
		if (a || o === "number" && (t = t.toString(), t === n)) return n;
		if (s) {
			let i = n[0];
			i && i.nodeType === 3 ? i.data !== t && (i.data = t) : i = document.createTextNode(t), n = xt(e, n, r, i);
		} else n = n !== "" && typeof n == "string" ? e.firstChild.data = t : e.textContent = t;
	} else if (t == null || o === "boolean") {
		if (a) return n;
		n = xt(e, n, r);
	} else if (o === "function") return N(() => {
		let i = t();
		for (; typeof i == "function";) i = i();
		n = vt(e, i, n, r);
	}), () => n;
	else if (Array.isArray(t)) {
		let o = [], c = n && Array.isArray(n);
		if (yt(o, t, n, i)) return N(() => n = vt(e, o, n, r, !0)), () => n;
		if (a) {
			if (!o.length) return n;
			if (r === void 0) return n = [...e.childNodes];
			let t = o[0];
			if (t.parentNode !== e) return n;
			let i = [t];
			for (; (t = t.nextSibling) !== r;) i.push(t);
			return n = i;
		}
		if (o.length === 0) {
			if (n = xt(e, n, r), s) return n;
		} else c ? n.length === 0 ? bt(e, o, r) : nt(e, n, o) : (n && xt(e), bt(e, o));
		n = o;
	} else if (t.nodeType) {
		if (a && t.parentNode) return n = s ? [t] : t;
		if (Array.isArray(n)) {
			if (s) return n = xt(e, n, r, t);
			xt(e, n, null, t);
		} else n == null || n === "" || !e.firstChild ? e.appendChild(t) : e.replaceChild(t, e.firstChild);
		n = t;
	}
	return n;
}
function yt(e, t, n, r) {
	let i = !1;
	for (let a = 0, o = t.length; a < o; a++) {
		let o = t[a], s = n && n[e.length], c;
		if (!(o == null || o === !0 || o === !1)) if ((c = typeof o) == "object" && o.nodeType) e.push(o);
		else if (Array.isArray(o)) i = yt(e, o, s) || i;
		else if (c === "function") if (r) {
			for (; typeof o == "function";) o = o();
			i = yt(e, Array.isArray(o) ? o : [o], Array.isArray(s) ? s : [s]) || i;
		} else e.push(o), i = !0;
		else {
			let t = String(o);
			s && s.nodeType === 3 && s.data === t ? e.push(s) : e.push(document.createTextNode(t));
		}
	}
	return i;
}
function bt(e, t, n = null) {
	for (let r = 0, i = t.length; r < i; r++) e.insertBefore(t[r], n);
}
function xt(e, t, n, r) {
	if (n === void 0) return e.textContent = "";
	let i = r || document.createTextNode("");
	if (t.length) {
		let r = !1;
		for (let a = t.length - 1; a >= 0; a--) {
			let o = t[a];
			if (i !== o) {
				let t = o.parentNode === e;
				!r && !a ? t ? e.replaceChild(i, o) : e.insertBefore(i, n) : t && o.remove();
			} else r = !0;
		}
	} else e.insertBefore(i, n);
	return [i];
}
function St() {
	return l.getNextContextId();
}
var Ct = "http://www.w3.org/2000/svg";
function wt(e, t = !1, n = void 0) {
	return t ? document.createElementNS(Ct, e) : document.createElement(e, { is: n });
}
function Tt(e) {
	let { useShadow: t } = e, n = document.createTextNode(""), r = () => e.mount || document.body, i = oe(), a, o = !!l.context;
	return P(() => {
		o && (oe().user = o = !1), a ||= se(i, () => F(() => e.children));
		let s = r();
		if (s instanceof HTMLHeadElement) {
			let [e, t] = j(!1);
			A((t) => X(s, () => e() ? t() : a(), null)), L(() => t(!0));
		} else {
			let r = wt(e.isSVG ? "g" : "div", e.isSVG), i = t && r.attachShadow ? r.attachShadow({ mode: "open" }) : r;
			Object.defineProperty(r, "_$host", {
				get() {
					return n.parentNode;
				},
				configurable: !0
			}), X(i, a), s.appendChild(r), e.ref && e.ref(r), L(() => s.removeChild(r));
		}
	}, void 0, { render: !o }), n;
}
function Et(e, t) {
	let n = F(e);
	return F(() => {
		let e = n();
		switch (typeof e) {
			case "function": return I(() => e(t));
			case "string":
				let n = et.has(e), r = l.context ? ft() : wt(e, n, I(() => t.is));
				return lt(r, t, n), r;
		}
	});
}
function Dt(e) {
	let [, t] = B(e, ["component"]);
	return Et(() => e.component, t);
}
//#endregion
//#region node_modules/.pnpm/proxy-compare@3.0.1/node_modules/proxy-compare/dist/index.js
var Ot = Symbol(), kt = Object.getPrototypeOf, At = /* @__PURE__ */ new WeakMap(), jt = (e) => e && (At.has(e) ? At.get(e) : kt(e) === Object.prototype || kt(e) === Array.prototype), Mt = (e) => jt(e) && e[Ot] || null, Nt = (e, t = !0) => {
	At.set(e, t);
}, Pt = (e) => typeof e == "object" && !!e, Ft = (e) => Pt(e) && !zt.has(e) && (Array.isArray(e) || !(Symbol.iterator in e)) && !(e instanceof WeakMap) && !(e instanceof WeakSet) && !(e instanceof Error) && !(e instanceof Number) && !(e instanceof Date) && !(e instanceof String) && !(e instanceof RegExp) && !(e instanceof ArrayBuffer) && !(e instanceof Promise), It = (e, t) => {
	let n = Bt.get(e);
	if (n?.[0] === t) return n[1];
	let r = Array.isArray(e) ? [] : Object.create(Object.getPrototypeOf(e));
	return Nt(r, !0), Bt.set(e, [t, r]), Reflect.ownKeys(e).forEach((t) => {
		if (Object.getOwnPropertyDescriptor(r, t)) return;
		let n = Reflect.get(e, t), { enumerable: i } = Reflect.getOwnPropertyDescriptor(e, t), a = {
			value: n,
			enumerable: i,
			configurable: !0
		};
		if (zt.has(n)) Nt(n, !1);
		else if (Rt.has(n)) {
			let [e, t] = Rt.get(n);
			a.value = It(e, t());
		}
		Object.defineProperty(r, t, a);
	}), r;
}, Lt = (e, t, n, r) => ({
	deleteProperty(e, t) {
		let i = Reflect.get(e, t);
		n(t);
		let a = Reflect.deleteProperty(e, t);
		return a && r(Jt?.("delete", t, i)), a;
	},
	set(i, a, o, s) {
		let c = !e() && Reflect.has(i, a), l = Reflect.get(i, a, s);
		if (c && (Ut(l, o) || Ht.has(o) && Ut(l, Ht.get(o)))) return !0;
		n(a), Pt(o) && (o = Mt(o) || o);
		let u = !Rt.has(o) && Gt(o) ? Yt(o) : o;
		return t(a, u), Reflect.set(i, a, u, s), r(Jt?.("set", a, o, l)), !0;
	}
}), Rt = /* @__PURE__ */ new WeakMap(), zt = /* @__PURE__ */ new WeakSet(), Bt = /* @__PURE__ */ new WeakMap(), Vt = [1], Ht = /* @__PURE__ */ new WeakMap(), Ut = Object.is, Wt = (e, t) => new Proxy(e, t), Gt = Ft, Kt = It, qt = Lt, Jt;
function Yt(e = {}) {
	if (!Pt(e)) throw Error("object required");
	let t = Ht.get(e);
	if (t) return t;
	let n = Vt[0], r = /* @__PURE__ */ new Set(), i = (e, t = ++Vt[0]) => {
		n !== t && (a = n = t, r.forEach((n) => n(e, t)));
	}, a = n, o = (e = Vt[0]) => (a !== e && (a = e, c.forEach(([t]) => {
		let r = t[1](e);
		r > n && (n = r);
	})), n), s = (e) => (t, n) => {
		let r;
		t && (r = [...t], r[1] = [e, ...r[1]]), i(r, n);
	}, c = /* @__PURE__ */ new Map(), l = (e, t) => {
		let n = !zt.has(t) && Rt.get(t);
		if (n) if (r.size) {
			let t = n[2](s(e));
			c.set(e, [n, t]);
		} else c.set(e, [n]);
	}, u = (e) => {
		var t;
		let n = c.get(e);
		n && (c.delete(e), (t = n[1]) == null || t.call(n));
	}, d = (e) => (r.add(e), r.size === 1 && c.forEach(([e, t], n) => {
		let r = e[2](s(n));
		c.set(n, [e, r]);
	}), () => {
		r.delete(e), r.size === 0 && c.forEach(([e, t], n) => {
			t && (t(), c.set(n, [e]));
		});
	}), f = !0, p = Wt(e, qt(() => f, l, u, i));
	Ht.set(e, p);
	let m = [
		e,
		o,
		d
	];
	return Rt.set(p, m), Reflect.ownKeys(e).forEach((t) => {
		let n = Object.getOwnPropertyDescriptor(e, t);
		"value" in n && n.writable && (p[t] = e[t]);
	}), f = !1, p;
}
function Xt(e, t, n) {
	let r = Rt.get(e), i, a = [], o = r[2], s = !1, c = o((e) => {
		if (e && a.push(e), n) {
			t(a.splice(0));
			return;
		}
		i ||= Promise.resolve().then(() => {
			i = void 0, s && t(a.splice(0));
		});
	});
	return s = !0, () => {
		s = !1, c();
	};
}
function Zt(e) {
	let [t, n] = Rt.get(e);
	return Kt(t, n());
}
//#endregion
//#region src/core/store.ts
function Qt(e) {
	let [t, n] = j(Zt(e));
	return L(Xt(e, () => n(Zt(e)))), t;
}
function $t(e, t, n, r) {
	let i = Yt(e);
	function a(e) {
		let o = t(i, e, n);
		r?.(e, i), o && o.execute(a).catch((e) => console.error("unhandled effect error:", e));
	}
	return {
		state: i,
		dispatch: a,
		getState: () => Qt(i)
	};
}
//#endregion
//#region src/core/effect.ts
var en = class e {
	runner;
	constructor(e) {
		this.runner = e;
	}
	static none() {
		return new e(() => Promise.resolve());
	}
	static send(t) {
		return new e((e) => (e(t), Promise.resolve()));
	}
	static fromPromise(t) {
		return new e((e) => t().then((t) => {
			e(t);
		}));
	}
	static merge(...t) {
		return new e((e) => Promise.all(t.map((t) => t.runner(e))).then(() => {}));
	}
	map(t) {
		return new e((e) => this.runner((n) => e(t(n))));
	}
	catch(t) {
		return new e((e) => this.runner(e).catch((n) => {
			e(t(n));
		}));
	}
	execute(e) {
		return this.runner(e);
	}
};
//#endregion
//#region src/core/reducer.ts
function tn(e, t, n, r, i) {
	return (a, o, s) => {
		let c = n(o);
		if (!c) return null;
		let l = e(t(a), c, i(s));
		return l ? l.map(r) : null;
	};
}
function nn(e, t, n, r, i, a) {
	return (o, s, c) => {
		let l = n(s);
		if (!l) return null;
		let u = [], d = {
			...i(c),
			navigate: (e) => (u.push(a(e)), en.none())
		}, f = e(t(o), l, d), p = u.length > 0 ? en.merge(...u.map((e) => en.send(e))) : null;
		return !f && !p ? null : f ? p ? en.merge(f.map(r), p) : f.map(r) : p;
	};
}
function rn(...e) {
	return (t, n, r) => {
		let i = [];
		for (let a of e) {
			let e = a(t, n, r);
			e && i.push(e);
		}
		return i.length > 0 ? en.merge(...i) : null;
	};
}
//#endregion
//#region src/features/navigation/routes.ts
function an(e) {
	switch (e.view) {
		case "dashboard": return "/";
		case "objects": return "/objects";
		case "objectDetail": return "/objects/" + encodeURIComponent(e.name);
		case "procedureDetail": return "/objects/" + encodeURIComponent(e.name) + "/" + encodeURIComponent(e.proc);
		case "proceduresList": return "/procedures";
		case "datawindows": return "/datawindows";
		case "dwDetail": return "/datawindows/" + encodeURIComponent(e.name);
		case "tables": return "/tables";
		case "tableDetail": return "/tables/" + encodeURIComponent(e.name);
		case "libraryDetail": return "/library/" + encodeURIComponent(e.name);
		case "diagrams": return "/diagrams";
		case "queries": {
			if (e.sqlText) return "/queries?" + new URLSearchParams({ sql: e.sqlText }).toString();
			if (!e.queryName) return "/queries";
			let t = new URLSearchParams({ q: e.queryName });
			if (e.queryParams) for (let [n, r] of Object.entries(e.queryParams)) t.set(`p_${n}`, r);
			return "/queries?" + t.toString();
		}
		case "search": return "/search";
		case "explore": return "/explore";
		case "errors": return "/errors";
		case "deadCode": return "/dead-code";
		case "taintExplorer": return "/taint";
		case "taintPathView": return "/taint/" + e.pathId;
		case "sliceView": return "/slice/" + encodeURIComponent(e.object) + "/" + encodeURIComponent(e.proc) + "/" + e.line + "?dir=" + e.direction;
		case "formalReports": return "/reports";
		case "cfgDiagram": return "/analysis/cfg/" + encodeURIComponent(e.object) + "/" + encodeURIComponent(e.proc);
		case "launch": return "/launch";
	}
}
function on(e, t) {
	let n = e.split("/").filter(Boolean);
	switch (n[0]) {
		case "objects": return n[2] ? {
			view: "procedureDetail",
			name: decodeURIComponent(n[1]),
			proc: decodeURIComponent(n[2])
		} : n[1] ? {
			view: "objectDetail",
			name: decodeURIComponent(n[1])
		} : { view: "objects" };
		case "datawindows": return n[1] ? {
			view: "dwDetail",
			name: decodeURIComponent(n[1])
		} : { view: "datawindows" };
		case "tables": return n[1] ? {
			view: "tableDetail",
			name: decodeURIComponent(n[1])
		} : { view: "tables" };
		case "library": return n[1] ? {
			view: "libraryDetail",
			name: decodeURIComponent(n[1])
		} : { view: "dashboard" };
		case "diagrams": return { view: "diagrams" };
		case "queries": {
			let e = t ? t.startsWith("?") ? t.slice(1) : t : "", n = new URLSearchParams(e), r = n.get("sql");
			if (r) return {
				view: "queries",
				sqlText: r
			};
			let i = n.get("q");
			if (!i) return { view: "queries" };
			let a = {};
			for (let [e, t] of n.entries()) e.startsWith("p_") && (a[e.slice(2)] = t);
			return {
				view: "queries",
				queryName: i,
				queryParams: a
			};
		}
		case "search": return { view: "search" };
		case "explore": return { view: "explore" };
		case "errors": return { view: "errors" };
		case "dead-code": return { view: "deadCode" };
		case "taint": return n[1] && /^\d+$/.test(n[1]) ? {
			view: "taintPathView",
			pathId: parseInt(n[1], 10)
		} : { view: "taintExplorer" };
		case "slice":
			if (n[1] && n[2] && n[3]) {
				let e = t ? t.startsWith("?") ? t.slice(1) : t : "", r = new URLSearchParams(e).get("dir") === "forward" ? "forward" : "backward";
				return {
					view: "sliceView",
					object: decodeURIComponent(n[1]),
					proc: decodeURIComponent(n[2]),
					line: parseInt(n[3], 10),
					direction: r
				};
			}
			return { view: "dashboard" };
		case "reports": return { view: "formalReports" };
		case "launch": return { view: "launch" };
		case "procedures": return { view: "proceduresList" };
		case "analysis": return n[1] === "cfg" && n[2] && n[3] ? {
			view: "cfgDiagram",
			object: decodeURIComponent(n[2]),
			proc: decodeURIComponent(n[3])
		} : { view: "dashboard" };
		default: return { view: "dashboard" };
	}
}
//#endregion
//#region src/features/navigation/breadcrumb.ts
var Z = {
	library: "library",
	window: "window",
	object: "object",
	procedure: "procedure",
	datawindow: "datawindow",
	table: "table",
	ask: "ask",
	analysis: "analysis",
	list: "list",
	launch: "launch"
};
function sn(e) {
	switch (e.view) {
		case "dashboard": return [{
			icon: Z.library,
			label: "Dashboard",
			route: e
		}];
		case "objects": return [{
			icon: Z.list,
			label: "Objects",
			route: e
		}];
		case "proceduresList": return [{
			icon: Z.list,
			label: "Procedures",
			route: e
		}];
		case "objectDetail": return [{
			icon: Z.list,
			label: "Objects",
			route: { view: "objects" }
		}, {
			icon: Z.object,
			label: e.name,
			route: e
		}];
		case "procedureDetail": return [
			{
				icon: Z.list,
				label: "Objects",
				route: { view: "objects" }
			},
			{
				icon: Z.object,
				label: e.name,
				route: {
					view: "objectDetail",
					name: e.name
				}
			},
			{
				icon: Z.procedure,
				label: e.proc,
				route: e
			}
		];
		case "datawindows": return [{
			icon: Z.list,
			label: "DataWindows",
			route: e
		}];
		case "dwDetail": return [{
			icon: Z.list,
			label: "DataWindows",
			route: { view: "datawindows" }
		}, {
			icon: Z.datawindow,
			label: e.name,
			route: e
		}];
		case "tables": return [{
			icon: Z.list,
			label: "Tables",
			route: e
		}];
		case "tableDetail": return [{
			icon: Z.list,
			label: "Tables",
			route: { view: "tables" }
		}, {
			icon: Z.table,
			label: e.name,
			route: e
		}];
		case "search": return [{
			icon: Z.list,
			label: "Search",
			route: e
		}];
		case "queries": return [{
			icon: Z.ask,
			label: "Ask",
			route: e
		}];
		case "diagrams": return [{
			icon: Z.analysis,
			label: "Schema / ERD",
			route: e
		}];
		case "deadCode": return [{
			icon: Z.analysis,
			label: "Dead Code",
			route: e
		}];
		case "taintExplorer": return [{
			icon: Z.analysis,
			label: "Taint Explorer",
			route: e
		}];
		case "taintPathView": return [{
			icon: Z.analysis,
			label: "Taint Explorer",
			route: { view: "taintExplorer" }
		}, {
			icon: Z.analysis,
			label: `Path ${e.pathId}`,
			route: e
		}];
		case "sliceView": return [
			{
				icon: Z.list,
				label: "Objects",
				route: { view: "objects" }
			},
			{
				icon: Z.object,
				label: e.object,
				route: {
					view: "objectDetail",
					name: e.object
				}
			},
			{
				icon: Z.procedure,
				label: e.proc,
				route: {
					view: "procedureDetail",
					name: e.object,
					proc: e.proc
				}
			},
			{
				icon: Z.analysis,
				label: `${e.direction === "backward" ? "Backward" : "Forward"} Slice (line ${e.line})`,
				route: e
			}
		];
		case "formalReports": return [{
			icon: Z.analysis,
			label: "Formal Reports",
			route: e
		}];
		case "errors": return [{
			icon: Z.analysis,
			label: "Diagnostics",
			route: e
		}];
		case "libraryDetail": return [{
			icon: Z.library,
			label: e.name,
			route: e
		}];
		case "explore": return [{
			icon: Z.analysis,
			label: "Explore",
			route: e
		}];
		case "cfgDiagram": return [
			{
				icon: Z.list,
				label: "Objects",
				route: { view: "objects" }
			},
			{
				icon: Z.object,
				label: e.object,
				route: {
					view: "objectDetail",
					name: e.object
				}
			},
			{
				icon: Z.procedure,
				label: e.proc,
				route: {
					view: "procedureDetail",
					name: e.object,
					proc: e.proc
				}
			},
			{
				icon: Z.analysis,
				label: "CFG",
				route: e
			}
		];
		case "launch": return [{
			icon: Z.launch,
			label: "Launch",
			route: e
		}];
	}
}
//#endregion
//#region src/features/navigation/reducer.ts
function cn(e, t, n) {
	switch (t.tag) {
		case "navigate": return e.route = t.route, e.crumbs = sn(t.route), e.askContext = null, e.history = [...e.history.slice(0, e.historyIdx + 1), t.route], e.historyIdx = e.history.length - 1, n.pushUrl(an(t.route)), null;
		case "navigate-from-ask": {
			e.route = t.route, e.askContext = {
				queryName: t.queryName,
				queryRoute: t.queryRoute
			};
			let r = {
				icon: Z.ask,
				label: t.queryName,
				route: t.queryRoute
			}, i = sn(t.route);
			return e.crumbs = [r, ...i[0]?.icon === Z.list ? i.slice(1) : i], e.history = [...e.history.slice(0, e.historyIdx + 1), t.route], e.historyIdx = e.history.length - 1, n.pushUrl(an(t.route)), null;
		}
		case "back":
			if (e.historyIdx > 0) {
				--e.historyIdx;
				let t = e.history[e.historyIdx];
				e.route = t, e.crumbs = sn(t), e.askContext = null, n.pushUrl(an(t));
			}
			return null;
		case "forward":
			if (e.historyIdx < e.history.length - 1) {
				e.historyIdx += 1;
				let t = e.history[e.historyIdx];
				e.route = t, e.crumbs = sn(t), e.askContext = null, n.pushUrl(an(t));
			}
			return null;
		default: return null;
	}
}
var ln = cn, un = {
	stats: null,
	topTables: [],
	topTablesLoaded: !1
};
function dn(e, t, n) {
	switch (t.tag) {
		case "load": return n.getStats().map((e) => ({
			tag: "loaded",
			stats: e
		}));
		case "loaded": return e.stats = t.stats, null;
		case "loadTopTables": return e.topTablesLoaded ? null : n.getTables().map((e) => ({
			tag: "topTablesLoaded",
			tables: e
		}));
		case "topTablesLoaded": return e.topTables = t.tables, e.topTablesLoaded = !0, null;
		default: return null;
	}
}
var fn = dn;
//#endregion
//#region src/features/explore/reducer.ts
function pn() {
	return {
		libraries: [],
		expandedNodes: /* @__PURE__ */ new Set(),
		selectedProc: null,
		selectedObject: null,
		highlightedProcName: null,
		selectedDw: null,
		procCache: {},
		dwCache: {},
		dwLayoutCache: {},
		objectSourceCache: {},
		loading: !1,
		activeTab: "source",
		treeFilter: "",
		highlightedLine: null,
		sidebarGroups: {
			sourceTree: !0,
			entityNav: !1,
			analysisNav: !1
		},
		sidebarCollapsed: !1,
		helpOverlayOpen: !1,
		tables: {
			items: [],
			filter: "",
			selected: null,
			detail: null,
			loading: !1,
			detailLoading: !1
		}
	};
}
function mn(e, t) {
	let n = e.libraries.find((e) => e.objects.some((e) => e.name === t));
	if (!n) return;
	let r = new Set(e.expandedNodes);
	r.add(`lib:${n.name}`), r.add(`obj:${n.name}:${t}`), e.expandedNodes = r, e.sidebarGroups = {
		...e.sidebarGroups,
		sourceTree: !0
	};
}
function hn(e, t, n) {
	switch (t.tag) {
		case "load": return e.loading = !0, n.getExploreTree().map((e) => ({
			tag: "loaded",
			data: e
		})).catch(() => ({
			tag: "loaded",
			data: { libraries: [] }
		}));
		case "loaded": return e.libraries = t.data.libraries, e.loading = !1, null;
		case "toggle": {
			let n = e.expandedNodes;
			if (n.has(t.nodeId)) {
				let r = new Set(n);
				r.delete(t.nodeId), e.expandedNodes = r;
			} else e.expandedNodes = new Set([...n, t.nodeId]);
			return null;
		}
		case "obj-select": return e.selectedObject = t.objectName, e.highlightedProcName = null, e.selectedProc = null, e.selectedDw = null, e.highlightedLine = null, e.sidebarGroups = {
			...e.sidebarGroups,
			sourceTree: !0
		}, n.navigate({
			tag: "navigate",
			route: { view: "explore" }
		}), t.objectName in e.objectSourceCache ? null : n.getObjectSource(t.objectName).map((e) => ({
			tag: "obj-loaded",
			objectName: t.objectName,
			data: e
		})).catch((e) => ({
			tag: "obj-error",
			objectName: t.objectName,
			error: String(e)
		}));
		case "obj-loaded": return e.objectSourceCache[t.objectName] = t.data, null;
		case "obj-error": return e.objectSourceCache[t.objectName] = { error: t.error }, null;
		case "proc-select": return e.selectedProc = t.nodeId, e.selectedObject = t.objectName, e.highlightedProcName = t.procName, e.selectedDw = null, e.activeTab = "source", e.highlightedLine = null, mn(e, t.objectName), n.navigate({
			tag: "navigate",
			route: { view: "explore" }
		}), t.objectName in e.objectSourceCache ? null : n.getObjectSource(t.objectName).map((e) => ({
			tag: "obj-loaded",
			objectName: t.objectName,
			data: e
		})).catch((e) => ({
			tag: "obj-error",
			objectName: t.objectName,
			error: String(e)
		}));
		case "proc-loaded": return e.procCache[t.nodeId] = t.data, null;
		case "proc-error": return e.procCache[t.nodeId] = { error: t.error }, null;
		case "expand-all": {
			let t = /* @__PURE__ */ new Set();
			for (let n of e.libraries) {
				t.add(`lib:${n.name}`);
				for (let e of n.objects) t.add(`obj:${n.name}:${e.name}`);
			}
			return e.expandedNodes = t, null;
		}
		case "collapse-all": return e.expandedNodes = /* @__PURE__ */ new Set(), null;
		case "dw-select": return e.selectedDw = t.nodeId, e.selectedProc = null, e.selectedObject = null, e.highlightedProcName = null, e.highlightedLine = null, mn(e, t.dwName), n.navigate({
			tag: "navigate",
			route: { view: "explore" }
		}), t.nodeId in e.dwCache ? null : en.merge(n.getExploreDatawindow(t.dwName).map((e) => ({
			tag: "dw-loaded",
			nodeId: t.nodeId,
			data: e
		})).catch((e) => ({
			tag: "dw-error",
			nodeId: t.nodeId,
			error: String(e)
		})), n.getDwLayout(t.dwName).map((e) => ({
			tag: "dw-layout-loaded",
			nodeId: t.nodeId,
			data: e
		})).catch(() => ({
			tag: "dw-layout-error",
			nodeId: t.nodeId
		})));
		case "dw-loaded": return e.dwCache[t.nodeId] = t.data, null;
		case "dw-error": return e.dwCache[t.nodeId] = { error: t.error }, null;
		case "dw-layout-loaded": return e.dwLayoutCache[t.nodeId] = t.data, null;
		case "dw-layout-error": return null;
		case "tab": return e.activeTab = t.tab, null;
		case "filter": return e.treeFilter = t.q, null;
		case "highlight-line": return e.highlightedLine = t.line, null;
		case "sidebar-toggle-group": return e.sidebarGroups = {
			...e.sidebarGroups,
			[t.group]: !e.sidebarGroups[t.group]
		}, null;
		case "sidebar-set-collapsed": return e.sidebarCollapsed = t.collapsed, null;
		case "sidebar-reveal": return mn(e, t.objectName), null;
		case "sidebar-focus-group": return e.sidebarGroups = {
			...e.sidebarGroups,
			[t.group]: !0
		}, e.sidebarCollapsed &&= !1, null;
		case "help-overlay-toggle": return e.helpOverlayOpen = !e.helpOverlayOpen, null;
		case "tables-load": return e.tables.loading = !0, n.getTables().map((e) => ({
			tag: "tables-loaded",
			items: e
		})).catch(() => ({
			tag: "tables-loaded",
			items: []
		}));
		case "tables-loaded": return e.tables.items = t.items, e.tables.loading = !1, null;
		case "tables-filter": return e.tables.filter = t.q, null;
		case "tables-select": return e.selectedDw = null, e.selectedProc = null, e.tables.selected = t.tableName, e.tables.detail = null, e.tables.detailLoading = !0, n.getTableDetail(t.tableName).map((e) => ({
			tag: "tables-detail-loaded",
			tableName: t.tableName,
			detail: e
		})).catch((e) => ({
			tag: "tables-detail-error",
			tableName: t.tableName,
			error: String(e)
		}));
		case "tables-detail-loaded": return e.tables.detail = t.detail, e.tables.detailLoading = !1, null;
		case "tables-detail-error": return e.tables.detail = { error: t.error }, e.tables.detailLoading = !1, null;
		default: return null;
	}
}
var gn = hn, _n = {
	items: [],
	total: 0,
	q: "",
	kind: "",
	sort: "name",
	order: "asc",
	offset: 0,
	loading: !1,
	detail: null,
	sourceDetail: null,
	astData: null,
	layout: null,
	selectedProcName: null,
	procedureDetail: null,
	allObjects: [],
	proceduresList: null,
	proceduresListLoading: !1,
	proceduresListQ: "",
	proceduresListKind: "",
	proceduresListSort: "name",
	proceduresListOrder: "asc"
};
function vn(e) {
	return e instanceof Error ? e.message : String(e);
}
function yn(e, t, n) {
	switch (t.tag) {
		case "back-to-objects": return e.detail = null, e.sourceDetail = null, e.astData = null, e.layout = null, e.procedureDetail = null, n.navigate({
			tag: "navigate",
			route: { view: "objects" }
		});
		case "search": {
			e.q = t.q, e.offset = 0, e.loading = !0;
			let r = {
				q: t.q,
				kind: e.kind,
				sort: e.sort,
				order: e.order,
				limit: 100,
				offset: 0
			};
			return n.getObjects(r).map((e) => ({
				tag: "loaded",
				data: e
			}));
		}
		case "filter-kind": {
			e.kind = t.kind, e.offset = 0, e.loading = !0;
			let r = {
				q: e.q,
				kind: t.kind,
				sort: e.sort,
				order: e.order,
				limit: 100,
				offset: 0
			};
			return n.getObjects(r).map((e) => ({
				tag: "loaded",
				data: e
			}));
		}
		case "sort": {
			e.order = e.sort === t.col && e.order === "asc" ? "desc" : "asc", e.sort = t.col, e.offset = 0, e.loading = !0;
			let r = {
				q: e.q,
				kind: e.kind,
				sort: t.col,
				order: e.order,
				limit: 100,
				offset: 0
			};
			return n.getObjects(r).map((e) => ({
				tag: "loaded",
				data: e
			}));
		}
		case "page": {
			e.offset = t.offset, e.loading = !0;
			let r = {
				q: e.q,
				kind: e.kind,
				sort: e.sort,
				order: e.order,
				limit: 100,
				offset: t.offset
			};
			return n.getObjects(r).map((e) => ({
				tag: "loaded",
				data: e
			}));
		}
		case "loaded": return e.items = t.data.items, e.total = t.data.total, e.loading = !1, null;
		case "select": return e.detail = null, e.sourceDetail = null, e.astData = null, e.layout = null, e.selectedProcName = null, n.navigate({
			tag: "navigate",
			route: {
				view: "objectDetail",
				name: t.name
			}
		}), en.merge(n.getObject(t.name).map((e) => ({
			tag: "detail-loaded",
			data: e
		})).catch((e) => ({
			tag: "detail-error",
			error: vn(e)
		})), n.getObjectSource(t.name).map((e) => ({
			tag: "source-loaded",
			data: e
		})).catch((e) => ({
			tag: "source-error",
			error: vn(e)
		})), n.getObjectAst(t.name).map((e) => ({
			tag: "ast-loaded",
			data: e
		})).catch((e) => ({
			tag: "ast-error",
			error: vn(e)
		})), n.getObjectLayout(t.name).map((e) => ({
			tag: "layout-loaded",
			data: e
		})).catch(() => ({
			tag: "layout-error",
			error: ""
		})));
		case "select-proc": return e.selectedProcName = t.procName, e.detail && "name" in e.detail && e.detail.name === t.objectName ? (n.navigate({
			tag: "navigate",
			route: {
				view: "objectDetail",
				name: t.objectName
			}
		}), null) : (e.detail = null, e.sourceDetail = null, e.astData = null, e.layout = null, n.navigate({
			tag: "navigate",
			route: {
				view: "objectDetail",
				name: t.objectName
			}
		}), en.merge(n.getObject(t.objectName).map((e) => ({
			tag: "detail-loaded",
			data: e
		})).catch((e) => ({
			tag: "detail-error",
			error: vn(e)
		})), n.getObjectSource(t.objectName).map((e) => ({
			tag: "source-loaded",
			data: e
		})).catch((e) => ({
			tag: "source-error",
			error: vn(e)
		})), n.getObjectAst(t.objectName).map((e) => ({
			tag: "ast-loaded",
			data: e
		})).catch((e) => ({
			tag: "ast-error",
			error: vn(e)
		})), n.getObjectLayout(t.objectName).map((e) => ({
			tag: "layout-loaded",
			data: e
		})).catch(() => ({
			tag: "layout-error",
			error: ""
		}))));
		case "detail-loaded": return e.detail = {
			...t.data,
			loading: !1
		}, null;
		case "detail-error": return e.detail = { error: t.error }, null;
		case "source-loaded": return e.sourceDetail = {
			...t.data,
			loading: !1
		}, null;
		case "source-error": return e.sourceDetail = { error: t.error }, null;
		case "ast-loaded": return e.astData = t.data, null;
		case "ast-error": return e.astData = { error: t.error }, null;
		case "layout-loaded": return e.layout = t.data, null;
		case "layout-error": return null;
		case "all-objects-loaded": return e.allObjects = t.data, null;
		case "proc-select": return e.procedureDetail = null, n.navigate({
			tag: "navigate",
			route: {
				view: "procedureDetail",
				name: t.objectName,
				proc: t.procName
			}
		}), n.getProcedure(t.objectName, t.procName).map((e) => ({
			tag: "proc-loaded",
			data: e
		})).catch((e) => ({
			tag: "proc-error",
			error: vn(e)
		}));
		case "proc-loaded": return e.procedureDetail = {
			...t.data,
			activeTab: "original",
			loading: !1
		}, null;
		case "proc-error": return e.procedureDetail = { error: t.error }, null;
		case "proc-tab": return e.procedureDetail && "activeTab" in e.procedureDetail && (e.procedureDetail.activeTab = t.tab), null;
		case "procs-list-load": return e.proceduresList === null ? (e.proceduresListLoading = !0, n.navigate({
			tag: "navigate",
			route: { view: "proceduresList" }
		}), n.getProcedures().map((e) => ({
			tag: "procs-list-loaded",
			data: e
		})).catch((e) => ({
			tag: "procs-list-error",
			error: vn(e)
		}))) : (n.navigate({
			tag: "navigate",
			route: { view: "proceduresList" }
		}), null);
		case "procs-list-loaded": return e.proceduresList = t.data, e.proceduresListLoading = !1, null;
		case "procs-list-error": return e.proceduresListLoading = !1, null;
		case "procs-list-filter": return e.proceduresListQ = t.q, null;
		case "procs-list-filter-kind": return e.proceduresListKind = t.kind, null;
		case "procs-list-sort": return e.proceduresListSort === t.col ? e.proceduresListOrder = e.proceduresListOrder === "asc" ? "desc" : "asc" : (e.proceduresListSort = t.col, e.proceduresListOrder = "asc"), null;
		case "go-slice": return n.navigate({
			tag: "navigate",
			route: {
				view: "sliceView",
				object: t.object,
				proc: t.proc,
				line: t.line,
				direction: t.direction
			}
		}), null;
		default: return null;
	}
}
var bn = yn, xn = {
	items: [],
	total: 0,
	q: "",
	loading: !1,
	dwDetail: null,
	dwLayout: null
};
function Sn(e) {
	return e instanceof Error ? e.message : String(e);
}
function Cn(e, t, n) {
	switch (t.tag) {
		case "back-to-datawindows": return e.dwDetail = null, n.navigate({
			tag: "navigate",
			route: { view: "datawindows" }
		});
		case "search": return e.q = t.q, e.loading = !0, n.navigate({
			tag: "navigate",
			route: { view: "datawindows" }
		}), n.getObjects({
			q: t.q,
			kind: "datawindow",
			limit: 200
		}).map((e) => ({
			tag: "loaded",
			data: e
		}));
		case "loaded": return e.items = t.data.items, e.total = t.data.total, e.loading = !1, null;
		case "select": return e.dwDetail = null, e.dwLayout = null, n.navigate({
			tag: "navigate",
			route: {
				view: "dwDetail",
				name: t.name
			}
		}), en.merge(n.getDW(t.name).map((e) => ({
			tag: "detail-loaded",
			data: e
		})).catch((e) => ({
			tag: "detail-error",
			error: Sn(e)
		})), n.getDwLayout(t.name).map((e) => ({
			tag: "layout-loaded",
			data: e
		})).catch(() => ({ tag: "layout-error" })));
		case "detail-loaded": return e.dwDetail = {
			...t.data,
			loading: !1
		}, null;
		case "layout-loaded": return e.dwLayout = t.data, null;
		case "layout-error": return null;
		case "detail-error": return e.dwDetail = { error: t.error }, null;
		default: return null;
	}
}
var wn = Cn, Tn = {
	items: [],
	total: 0,
	q: "",
	loading: !1,
	detail: null,
	error: null
};
//#endregion
//#region src/features/tables/reducer.ts
function En(e) {
	return e instanceof Error ? e.message : String(e);
}
function Dn(e, t, n) {
	switch (t.tag) {
		case "filter": return e.q = t.q, null;
		case "search": return e.q = t.q, e.loading = !0, n.navigate({
			tag: "navigate",
			route: { view: "tables" }
		}), n.getTables().map((e) => ({
			tag: "loaded",
			items: e
		}));
		case "loaded": return e.items = t.items, e.total = t.items.length, e.loading = !1, null;
		case "select": return e.detail = null, e.error = null, n.navigate({
			tag: "navigate",
			route: {
				view: "tableDetail",
				name: t.name
			}
		}), n.getTableDetail(t.name).map((e) => ({
			tag: "detail-loaded",
			detail: e
		})).catch((e) => ({
			tag: "detail-error",
			error: En(e)
		}));
		case "detail-loaded": return e.detail = t.detail, e.loading = !1, null;
		case "detail-error": return e.error = t.error, e.loading = !1, null;
		case "back": return e.detail = null, e.error = null, n.navigate({
			tag: "navigate",
			route: { view: "tables" }
		}), null;
		default: return null;
	}
}
var On = Dn, kn = {
	active: "inheritance",
	svg: null,
	loading: !1,
	params: {},
	tableNames: [],
	objectNames: [],
	itemsLoaded: !1
};
function An(e, t, n) {
	switch (t.tag) {
		case "select": return e.active = t.kind, e.svg = null, e.loading = !1, null;
		case "params": return Object.assign(e.params, t.params), null;
		case "generate": return e.loading = !0, n.getDiagram(e.active, e.params).map((e) => ({
			tag: "loaded",
			svg: e
		})).catch((e) => ({
			tag: "error",
			error: String(e)
		}));
		case "loaded": return e.svg = t.svg, e.loading = !1, null;
		case "error": return e.svg = null, e.loading = !1, e.error = t.error, null;
		case "loadItems": return e.itemsLoaded ? null : en.merge(n.getTables().map((t) => ({
			tag: "itemsLoaded",
			tableNames: t.map((e) => e.table_name),
			objectNames: e.objectNames
		})), n.getAllObjects().map((t) => ({
			tag: "itemsLoaded",
			tableNames: e.tableNames,
			objectNames: t.items.map((e) => e.name)
		})));
		case "itemsLoaded": return t.tableNames.length > 0 && (e.tableNames = t.tableNames), t.objectNames.length > 0 && (e.objectNames = t.objectNames), e.tableNames.length > 0 && e.objectNames.length > 0 && (e.itemsLoaded = !0), null;
		default: return null;
	}
}
var jn = An, Mn = {
	items: [],
	results: null,
	resultsName: "",
	queryParams: {},
	sortCol: null,
	sortDir: "asc",
	page: 0,
	loading: !1,
	askText: "",
	generatedSql: null,
	queryPaneOpen: !1,
	recentQueries: [],
	isSqlMode: !1
};
function Nn(e, t, n) {
	switch (e) {
		case "object": return {
			view: "objectDetail",
			name: t
		};
		case "procedure": return n ? {
			view: "procedureDetail",
			name: n,
			proc: t
		} : null;
		case "datawindow": return {
			view: "dwDetail",
			name: t
		};
		case "table": return {
			view: "tableDetail",
			name: t
		};
		default: return null;
	}
}
function Pn(e) {
	let t = e.trimStart().toUpperCase();
	return t.startsWith("SELECT") || t.startsWith("WITH");
}
function Fn(e, t) {
	return [t, ...e.filter((e) => e !== t)].slice(0, 5);
}
function In(e, t, n) {
	return e.generatedSql = t, e.resultsName = t.slice(0, 50), e.isSqlMode = !0, e.results = null, e.page = 0, e.loading = !0, e.recentQueries = Fn(e.recentQueries, t), n.navigate({
		tag: "navigate",
		route: {
			view: "queries",
			sqlText: t
		}
	}), n.runSql(t).map((e) => ({
		tag: "result",
		data: e
	})).catch((e) => ({
		tag: "error",
		error: String(e)
	}));
}
function Ln(e, t, n) {
	switch (t.tag) {
		case "load": return e.loading = !0, n.getQueries().map((e) => ({
			tag: "loaded",
			items: e.queries
		}));
		case "loaded": return e.items = t.items, e.loading = !1, null;
		case "run": return e.results = null, e.resultsName = t.name, e.queryParams = t.params, e.isSqlMode = !1, e.page = 0, n.navigate({
			tag: "navigate",
			route: {
				view: "queries",
				queryName: t.name,
				queryParams: t.params
			}
		}), n.runQuery(t.name, t.params).map((e) => ({
			tag: "result",
			data: e
		})).catch((e) => ({
			tag: "error",
			error: String(e)
		}));
		case "result": return e.results = t.data, e.loading = !1, null;
		case "error": return e.results = { error: t.error }, e.loading = !1, e.queryPaneOpen = !0, null;
		case "restore": return e.resultsName === t.name && e.results !== null ? null : (e.resultsName = t.name, e.queryParams = t.params, n.runQuery(t.name, t.params).map((e) => ({
			tag: "result",
			data: e
		})).catch((e) => ({
			tag: "error",
			error: String(e)
		})));
		case "navigate-to-entity": {
			let r = Nn(t.entityType, t.entityName, t.objectName);
			if (!r) return null;
			let i = e.isSqlMode && e.generatedSql ? {
				view: "queries",
				sqlText: e.generatedSql
			} : {
				view: "queries",
				queryName: e.resultsName,
				queryParams: e.queryParams
			};
			return n.navigate({
				tag: "navigate-from-ask",
				route: r,
				queryName: e.resultsName,
				queryRoute: i
			}), null;
		}
		case "sort": return e.sortCol === t.col ? e.sortDir = e.sortDir === "asc" ? "desc" : "asc" : (e.sortCol = t.col, e.sortDir = "asc"), e.page = 0, null;
		case "set-page": return e.page = t.page, null;
		case "set-ask-text": return e.askText = t.text, null;
		case "submit-ask": {
			let t = e.askText.trim();
			return t ? Pn(t) ? In(e, e.askText.trim(), n) : (e.results = { error: "NL translation is not available at P1 — start your question with SELECT or WITH to query directly." }, null) : null;
		}
		case "toggle-query-pane": return e.queryPaneOpen = !e.queryPaneOpen, null;
		case "set-generated-sql": return e.generatedSql = t.sql, null;
		case "run-sql": return In(e, t.sql, n);
		case "run-recent": return e.askText = t.text, In(e, t.text, n);
		default: return null;
	}
}
var Rn = Ln, zn = {
	term: "",
	results: null,
	loading: !1,
	recentSearches: [],
	overlayOpen: !1,
	overlayTerm: "",
	overlayResults: null,
	overlayLoading: !1
}, Bn = 5;
function Vn(e, t) {
	return [t, ...e.filter((e) => e !== t)].slice(0, Bn);
}
function Hn(e, t, n) {
	switch (t.tag) {
		case "term": return e.term = t.term, t.term.length < 2 ? null : (e.recentSearches = Vn(e.recentSearches, t.term), n.search(t.term).map((e) => ({
			tag: "loaded",
			data: e
		})));
		case "loaded": return e.results = t.data, e.loading = !1, null;
		case "overlay-open": return e.overlayOpen = !0, e.overlayTerm = "", e.overlayResults = null, null;
		case "overlay-close": return e.overlayOpen = !1, null;
		case "overlay-term": return e.overlayTerm = t.term, t.term.length < 2 ? (e.overlayResults = null, null) : (e.overlayLoading = !0, n.search(t.term).map((e) => ({
			tag: "overlay-loaded",
			data: e
		})));
		case "overlay-loaded": return e.overlayResults = t.data, e.overlayLoading = !1, null;
		default: return null;
	}
}
var Un = Hn, Wn = {
	items: [],
	total: 0,
	loading: !1,
	filterKind: "all",
	query: "",
	page: 0,
	selected: null
};
function Gn(e, t) {
	return t.getErrors({
		kind: e.filterKind === "all" ? void 0 : e.filterKind,
		q: e.query || void 0,
		limit: 100,
		offset: e.page * 100
	}).map((e) => ({
		tag: "loaded",
		items: e.items,
		total: e.total
	})).catch((e) => ({
		tag: "error",
		error: String(e)
	}));
}
function Kn(e, t, n) {
	switch (t.tag) {
		case "load": return e.loading = !0, Gn(e, n);
		case "loaded": return e.items = t.items, e.total = t.total, e.loading = !1, null;
		case "setFilterKind": return e.filterKind = t.kind, e.page = 0, e.loading = !0, Gn(e, n);
		case "setQuery": return e.query = t.query, e.page = 0, e.loading = !0, Gn(e, n);
		case "setPage": return e.page = t.page, e.loading = !0, Gn(e, n);
		case "select": return e.selected = t.row, null;
		case "error": return e.loading = !1, null;
		default: return null;
	}
}
var qn = Kn;
//#endregion
//#region src/core/cps/load.ts
function Jn(e) {
	switch (e.tag) {
		case "CpsAssign": return {
			kind: "assign",
			var: e.var,
			rhs: e.rhs,
			next: e.next
		};
		case "CpsBranch": return {
			kind: "branch",
			cond: e.cond,
			then_: e.thenPc,
			else_: e.elsePc
		};
		case "CpsGoto": return {
			kind: "goto",
			target: e.target
		};
		case "CpsCall": return {
			kind: "call",
			callee: e.callee,
			args: e.args ?? [],
			result: e.result,
			next: e.next
		};
		case "CpsSuspend": return {
			kind: "suspend",
			effect: e.effect,
			args: e.args ?? [],
			var: e.var,
			continuation: e.continuation
		};
		case "CpsReturn": return {
			kind: "return",
			value: e.value
		};
		case "CpsNop": return {
			kind: "nop",
			next: e.next
		};
		case "CpsCallProc": return {
			kind: "callproc",
			callee: e.callee,
			args: e.args ?? [],
			next: e.next
		};
		default: return null;
	}
}
function Yn(e) {
	let t = e;
	return {
		nodes: (t.nodes ?? []).map(Jn).filter((e) => e !== null),
		entry: t.entry ?? 0,
		suspensionPoints: t.suspensionPoints ?? [],
		sourceMap: new Map(t.sourceMap ?? [])
	};
}
//#endregion
//#region src/core/runtime.ts
var Xn = {
	mid: (e, t, n) => {
		let r = String(e), i = Number(t) - 1;
		return n == null ? r.substring(i) : r.substring(i, i + Number(n));
	},
	left: (e, t) => String(e).substring(0, Number(t)),
	right: (e, t) => String(e).slice(-Number(t)),
	len: (e) => String(e).length,
	pos: (e, t) => String(e).indexOf(String(t)) + 1,
	trim: (e) => String(e).trim(),
	upper: (e) => String(e).toUpperCase(),
	lower: (e) => String(e).toLowerCase(),
	space: (e) => " ".repeat(Math.max(0, Number(e))),
	fill: (e, t) => String(t).repeat(Math.max(0, Number(e))),
	reverse: (e) => String(e).split("").reverse().join(""),
	replace: (e, t, n) => String(e).split(String(t)).join(String(n)),
	string: (e) => String(e),
	integer: (e) => parseInt(String(e), 10) || 0,
	long: (e) => parseInt(String(e), 10) || 0,
	real: (e) => parseFloat(String(e)) || 0,
	dec: (e) => parseFloat(String(e)) || 0,
	char: (e) => String.fromCharCode(Number(e)),
	isnull: (e) => e == null,
	isnumber: (e) => !isNaN(Number(e)) && e != null,
	isdate: () => !1,
	istime: () => !1,
	abs: (e) => Math.abs(Number(e)),
	mod: (e, t) => Number(e) % Number(t),
	max: (e, t) => Math.max(Number(e), Number(t)),
	min: (e, t) => Math.min(Number(e), Number(t)),
	round: (e, t) => {
		let n = 10 ** Number(t);
		return Math.round(Number(e) * n) / n;
	},
	ceiling: (e) => Math.ceil(Number(e)),
	floor: (e) => Math.floor(Number(e)),
	sign: (e) => Math.sign(Number(e)),
	rgb: (e, t, n) => Number(e) << 16 | Number(t) << 8 | Number(n),
	trn: (e) => `[${e}]`,
	tr: (e) => `[${e}]`,
	messagebox: (e, t, n, r) => {
		typeof window < "u" && typeof window.alert == "function" && window.alert(`${e}: ${t}`);
	},
	retrieve: () => []
};
//#endregion
//#region src/core/cps/var-env.ts
function Zn() {
	return {
		globals: {},
		instance: {},
		locals: [{}]
	};
}
function Qn(e, t) {
	for (let n = e.locals.length - 1; n >= 0; n--) if (Object.prototype.hasOwnProperty.call(e.locals[n], t)) return e.locals[n][t];
	return Object.prototype.hasOwnProperty.call(e.instance, t) ? e.instance[t] : e.globals[t];
}
function $n(e, t, n) {
	for (let r = e.locals.length - 1; r >= 0; r--) if (Object.prototype.hasOwnProperty.call(e.locals[r], t)) {
		e.locals[r][t] = n;
		return;
	}
	if (Object.prototype.hasOwnProperty.call(e.instance, t)) {
		e.instance[t] = n;
		return;
	}
	if (Object.prototype.hasOwnProperty.call(e.globals, t)) {
		e.globals[t] = n;
		return;
	}
	e.locals[e.locals.length - 1][t] = n;
}
function er(e) {
	e.locals.push({});
}
function tr(e) {
	e.locals.length > 1 && e.locals.pop();
}
function nr(e) {
	let t = {
		...e.globals,
		...e.instance
	};
	for (let n of e.locals) t = {
		...t,
		...n
	};
	return t;
}
//#endregion
//#region src/core/cps/expr.ts
function rr(e, t) {
	switch (t.tag) {
		case "ExBool": return t.contents;
		case "ExInt": return parseInt(t.contents, 10);
		case "ExReal": return parseFloat(t.contents);
		case "ExStr": return t.contents;
		case "ExDate": return t.contents;
		case "ExTime": return t.contents;
		case "ExNull": return null;
		case "ExEnum": return t.contents;
		case "ExLvalue": {
			let n = t.contents.segments[0]?.name;
			return n ? Qn(e, n) : void 0;
		}
		case "ExCall": {
			let n = t.callee.segments.map((e) => e.name).join("."), r = t.args.map((t) => ir(e, t)), i = Xn[n];
			return i ? i(...r) : void 0;
		}
		case "ExBinOp": return ar(rr(e, t.lhs), t.op, rr(e, t.rhs));
		case "ExNot": return !rr(e, t.contents);
		case "ExNeg": return -rr(e, t.contents);
		default: return;
	}
}
function ir(e, t) {
	if (t.length === 0) return;
	let n = t.join("").trim();
	if (n === "null") return null;
	if (n === "true") return !0;
	if (n === "false") return !1;
	if (n.startsWith("\"") && n.endsWith("\"")) return n.slice(1, -1);
	if (/^-?\d+$/.test(n)) return parseInt(n, 10);
	if (/^-?\d+\.\d+$/.test(n)) return parseFloat(n);
	if (/^[a-zA-Z_]/.test(n)) {
		let t = n.indexOf(".");
		return Qn(e, t >= 0 ? n.slice(0, t) : n);
	}
	return n;
}
function ar(e, t, n) {
	switch (t) {
		case "BopAdd": return e + n;
		case "BopSub": return e - n;
		case "BopMul": return e * n;
		case "BopDiv": return e / n;
		case "BopPow": return e ** +n;
		case "BopEq": return e === n;
		case "BopNe": return e !== n;
		case "BopLt": return e < n;
		case "BopGt": return e > n;
		case "BopLe": return e <= n;
		case "BopGe": return e >= n;
		case "BopAnd": return !!e && !!n;
		case "BopOr": return !!e || !!n;
		case "BopXor": return !!e != !!n;
		default: return;
	}
}
//#endregion
//#region src/core/cps/runner.ts
function or(e, t, n, r) {
	if (t < 0 || t >= e.nodes.length) return null;
	let i = e.nodes[t];
	switch (i.kind) {
		case "return": return null;
		case "assign": return $n(n, i.var, rr(n, i.rhs)), or(e, i.next, n, r);
		case "branch": return rr(n, i.cond) ? or(e, i.then_, n, r) : or(e, i.else_, n, r);
		case "goto": return or(e, i.target, n, r);
		case "call": {
			let t = Xn[i.callee];
			if (t) {
				let e = i.args.map((e) => rr(n, e));
				i.result && $n(n, i.result, t(...e));
			}
			return or(e, i.next, n, r);
		}
		case "suspend": {
			let t = i.args.map((e) => rr(n, e)), a = sr(i.effect, t, r);
			return a ? a.map((e) => ({
				tag: "cps-resume",
				pc: i.continuation,
				var: i.var ?? null,
				value: e
			})) : or(e, i.continuation, n, r);
		}
		case "nop": return or(e, i.next, n, r);
		case "callproc": {
			let e = i.args.map((e) => rr(n, e));
			return en.send({
				tag: "cps-dispatch",
				callee: i.callee,
				args: e,
				resumePc: i.next
			});
		}
		default: return null;
	}
}
function sr(e, t, n) {
	if (e.startsWith("retrieve:")) {
		let r = e.slice(9), i = n.dwNameToSql?.(r) ?? null;
		return i ? n.executeSql(i, t).map((e) => ({
			dwName: r,
			rows: e.rows
		})) : null;
	}
	switch (e) {
		case "executeSql": {
			let e = String(t[0] ?? ""), r = t.slice(1);
			return n.executeSql(e, r).map((e) => e.rows);
		}
		case "open":
		case "opensheet": {
			let e = String(t[0] ?? "");
			return n.open(e);
		}
		default: return null;
	}
}
//#endregion
//#region src/features/runtime/reducer.ts
var cr = {
	gs_kodxrisi: "0001",
	gs_app_name: "OpenPay",
	gs_username: "admin"
}, lr = {
	ast: null,
	layout: null,
	varEnv: Zn(),
	controlValues: {},
	dwQueries: {},
	cpsGraph: null,
	callStack: [],
	status: "idle",
	error: null
};
function ur(e, t) {
	if (!e) return null;
	for (let n of e.typeBlocks) if (n.decl.within !== null && n.decl.name === t) {
		for (let e of n.body) if (e.node.tag === "BsLocalVar" && e.node.name === "dataobject" && e.node.init?.tag === "ExStr") return e.node.init.contents;
	}
	return null;
}
function dr(e, t, n, r) {
	let i = {
		executeSql: r.executeSql,
		open: () => en.none(),
		dwNameToSql: (e) => {
			if (n.dwQueries[e]) return n.dwQueries[e] ?? null;
			let t = ur(n.ast, e);
			return t ? n.dwQueries[t] ?? null : null;
		}
	}, a = or(e, t, n.varEnv, i);
	return a ? (n.status = "awaiting-sql", a.map((e) => {
		if (e.tag === "cps-dispatch") return {
			tag: "cps-dispatch",
			callee: e.callee,
			args: e.args,
			resumePc: e.resumePc
		};
		let { dwName: t, rows: n } = e.value;
		return {
			tag: "cps-resume",
			dwName: t,
			rows: n,
			pc: e.pc,
			varName: e.var
		};
	}).catch((e) => ({
		tag: "error",
		message: String(e)
	}))) : (n.cpsGraph = null, n.callStack.length > 0 ? hr(n, r) : (n.status = "done", null));
}
function fr(e, t, n) {
	let r = `${t}::${n}`.toLowerCase();
	for (let t of e.events) if (`${t.owner}::${t.name}`.toLowerCase() === r) return t;
	for (let t of e.functions ?? []) if (`${t.owner}::${t.name}`.toLowerCase() === r) return t;
	return null;
}
function pr(e, t) {
	let n = t.toLowerCase();
	for (let t of e.events) if (t.name.toLowerCase() === n) return t;
	for (let t of e.ancestorEvents ?? []) if (t.name.toLowerCase() === n) return t;
	for (let t of e.functions ?? []) if (t.name.toLowerCase() === n) return t;
	for (let t of e.ancestorFunctions ?? []) if (t.name.toLowerCase() === n) return t;
	return null;
}
function mr(e, t, n) {
	if (!e) return null;
	if (t === "triggerevent") return pr(e, String(n[0] ?? ""));
	if (t.toLowerCase().startsWith("super::")) {
		let n = (t.split("::")[1] ?? "").toLowerCase();
		for (let t of e.ancestorEvents ?? []) if (t.name.toLowerCase() === n) return t;
		for (let t of e.ancestorFunctions ?? []) if (t.name.toLowerCase() === n) return t;
		return null;
	}
	return pr(e, t.includes("::") ? t.split("::")[1] ?? "" : t);
}
function hr(e, t) {
	tr(e.varEnv);
	let n = e.callStack.pop();
	return n ? (e.cpsGraph = n.graph, dr(n.graph, n.resumePc, e, t)) : (e.cpsGraph = null, e.status = "done", null);
}
function gr(e, t, n) {
	let r = Yn(t.cpsGraph);
	return e.cpsGraph = r, dr(r, r.entry, e, n);
}
function _r(e, t, n) {
	switch (t.tag) {
		case "set-ast": return e.ast = t.ast, e.varEnv = Zn(), e.controlValues = {}, e.cpsGraph = null, e.callStack = [], e.status = "idle", e.error = null, n.getDwQueries().map((e) => ({
			tag: "dw-queries-loaded",
			queries: e
		})).catch(() => ({
			tag: "dw-queries-loaded",
			queries: {}
		}));
		case "layout-loaded": return e.layout = t.layout, null;
		case "dw-queries-loaded": return e.dwQueries = t.queries, null;
		case "run-event": {
			if (!e.ast) return null;
			e.varEnv.locals = [{}];
			for (let [n, r] of Object.entries(t.globals ?? cr)) n in e.varEnv.globals || (e.varEnv.globals[n] = r);
			let r = e.ast.typeBlocks.find((e) => e.decl.within == null);
			if (r) for (let t of r.body) {
				let n = t.node;
				n.tag === "BsLocalVar" && n.init && !(n.name in e.varEnv.instance) && (e.varEnv.instance[n.name] = rr(e.varEnv, n.init));
			}
			e.status = "running";
			let i = fr(e.ast, t.owner, t.event);
			return i ? gr(e, i, n) : (e.status = "done", null);
		}
		case "control-click": {
			if (!e.ast) return null;
			e.varEnv.locals = [{}], e.status = "running";
			let r = fr(e.ast, t.controlName, "clicked");
			return r ? gr(e, r, n) : (e.status = "done", null);
		}
		case "cps-resume": {
			e.controlValues[t.dwName] = t.rows;
			let r = e.cpsGraph;
			return r ? dr(r, t.pc, e, n) : (e.status = "done", null);
		}
		case "cps-dispatch": {
			let r = e.cpsGraph;
			if (!r) return null;
			er(e.varEnv), e.callStack.push({
				graph: r,
				resumePc: t.resumePc
			}), e.cpsGraph = null, e.status = "running";
			let i = mr(e.ast, t.callee, t.args);
			return i ? gr(e, i, n) : hr(e, n);
		}
		case "error": return e.status = "error", e.error = t.message, null;
	}
}
var vr = _r, yr = 800, br = 600, xr = 200, Sr = 150, Cr = 40;
function wr(e) {
	let t = e.windows.length % 5 * 30;
	return {
		x: Cr + t,
		y: Cr + t
	};
}
function Tr(e, t) {
	return e.windows.find((e) => e.id === t);
}
function Er(e, t, n) {
	let r = e.windows.findIndex((e) => e.id === t);
	r >= 0 && (e.windows[r] = {
		...e.windows[r],
		...n
	});
}
function Dr(e, t) {
	switch (t.tag) {
		case "open-window": {
			let n = wr(e);
			return e.windows.push({
				id: t.id,
				title: t.title,
				x: n.x,
				y: n.y,
				width: yr,
				height: br,
				zIndex: e.nextZIndex,
				minimized: !1,
				maximized: !1,
				runtimeWindowName: t.runtimeWindowName
			}), e.activeWindowId = t.id, e.nextZIndex++, null;
		}
		case "close-window": return e.windows = e.windows.filter((e) => e.id !== t.id), e.activeWindowId === t.id && (e.activeWindowId = (e.windows.length > 0 ? e.windows.reduce((e, t) => e.zIndex > t.zIndex ? e : t) : null)?.id ?? null), null;
		case "focus-window": {
			let n = Tr(e, t.id);
			return n && (n.zIndex = e.nextZIndex, e.nextZIndex++, e.activeWindowId = t.id), null;
		}
		case "move-window": return Er(e, t.id, {
			x: t.x,
			y: t.y
		}), null;
		case "resize-window": return Er(e, t.id, {
			width: Math.max(xr, t.width),
			height: Math.max(Sr, t.height)
		}), null;
		case "minimize-window":
			if (Er(e, t.id, { minimized: !0 }), e.activeWindowId === t.id) {
				let n = e.windows.filter((e) => !e.minimized && e.id !== t.id);
				e.activeWindowId = (n.length > 0 ? n.reduce((e, t) => e.zIndex > t.zIndex ? e : t) : null)?.id ?? null;
			}
			return null;
		case "maximize-window": return Er(e, t.id, {
			maximized: !0,
			minimized: !1
		}), e.activeWindowId = t.id, null;
		case "restore-window": return Er(e, t.id, {
			maximized: !1,
			minimized: !1
		}), e.activeWindowId = t.id, null;
	}
}
var Or = Dr, kr = {
	windows: [],
	activeWindowId: null,
	nextZIndex: 1
}, Ar = {
	gs_kodxrisi: "0001",
	gs_descxrisi: "Demo",
	gs_app_name: "OpenPay",
	gs_username: "admin",
	gs_version_number: "0.1.1b",
	gs_version_date: "22/12/2005",
	gs_dbver_req: "0.1.1",
	gs_copyright_year: "2005-2006",
	gs_serialnumber: "GPL",
	gs_country: "uk",
	gb_useperm: !1,
	gs_kodapp: "openpay"
}, jr = {
	status: "idle",
	appName: null,
	globals: {},
	windowStack: [],
	error: null
};
function Mr(e, t, n) {
	switch (t.tag) {
		case "load-app": return e.status = "loading", e.appName = t.sraName, e.error = null, n.getObjectAst(t.sraName).map((e) => ({
			tag: "app-loaded",
			ast: e
		})).catch((e) => ({
			tag: "launch-error",
			message: String(e)
		}));
		case "app-loaded":
			if (e.globals = { ...Ar }, e.status = "running", t.ast.variables) for (let n of t.ast.variables) !(n.name in e.globals) && n.scope === "global" && (e.globals[n.name] = void 0);
			return en.send({
				tag: "run-app-open",
				windowName: "w_misth_final_form_create"
			});
		case "run-app-open": return n.getObjectAst(t.windowName).map((e) => ({
			tag: "window-ast-loaded",
			windowName: t.windowName,
			ast: e
		})).catch((e) => ({
			tag: "launch-error",
			message: String(e)
		}));
		case "window-ast-loaded": return e.windowStack.push(t.windowName), e.status = "done", null;
		case "close-window": return e.windowStack = e.windowStack.filter((e) => e !== t.windowName), e.windowStack.length === 0 && (e.status = "done"), null;
		case "launch-error": return e.status = "error", e.error = t.message, null;
	}
}
var Nr = Mr, Pr = (e) => e.tag === "nav" ? e.action : null, Fr = (e) => e.tag === "dashboard" ? e.action : null, Ir = (e) => e.tag === "explore" ? e.action : null, Lr = (e) => e.tag === "objects" ? e.action : null, Rr = (e) => e.tag === "datawindows" ? e.action : null, zr = (e) => e.tag === "tables" ? e.action : null, Br = (e) => e.tag === "diagrams" ? e.action : null, Vr = (e) => e.tag === "queries" ? e.action : null, Hr = (e) => e.tag === "search" ? e.action : null, Ur = (e) => e.tag === "errors" ? e.action : null, Wr = (e) => e.tag === "windowManager" ? e.action : null, Gr = (e) => e.tag === "launch" ? e.action : null;
function Kr() {
	return {
		theme: "dark",
		nav: {
			route: { view: "dashboard" },
			crumbs: sn({ view: "dashboard" }),
			history: [{ view: "dashboard" }],
			historyIdx: 0,
			askContext: null
		},
		dashboard: un,
		objects: _n,
		datawindows: xn,
		tables: Tn,
		diagrams: kn,
		queries: Mn,
		search: zn,
		explore: pn(),
		errors: Wn,
		inlineDiagrams: {},
		runtimes: {},
		windowManager: kr,
		launch: jr
	};
}
var qr = (e) => ({
	tag: "nav",
	action: e
}), Jr = rn(tn(ln, (e) => e.nav, Pr, (e) => ({
	tag: "nav",
	action: e
}), (e) => e), tn(fn, (e) => e.dashboard, Fr, (e) => ({
	tag: "dashboard",
	action: e
}), (e) => e), nn(gn, (e) => e.explore, Ir, (e) => ({
	tag: "explore",
	action: e
}), (e) => e, qr), nn(bn, (e) => e.objects, Lr, (e) => ({
	tag: "objects",
	action: e
}), (e) => e, qr), nn(wn, (e) => e.datawindows, Rr, (e) => ({
	tag: "datawindows",
	action: e
}), (e) => e, qr), nn(On, (e) => e.tables, zr, (e) => ({
	tag: "tables",
	action: e
}), (e) => e, qr), nn(jn, (e) => e.diagrams, Br, (e) => ({
	tag: "diagrams",
	action: e
}), (e) => e, qr), nn(Rn, (e) => e.queries, Vr, (e) => ({
	tag: "queries",
	action: e
}), (e) => e, qr), nn(Un, (e) => e.search, Hr, (e) => ({
	tag: "search",
	action: e
}), (e) => e, qr), tn(qn, (e) => e.errors, Ur, (e) => ({
	tag: "errors",
	action: e
}), (e) => e), tn(Or, (e) => e.windowManager, Wr, (e) => ({
	tag: "windowManager",
	action: e
}), () => void 0), tn(Nr, (e) => e.launch, Gr, (e) => ({
	tag: "launch",
	action: e
}), (e) => ({ getObjectAst: e.getObjectAst })));
function Yr(e, t, n) {
	if (t.tag === "runtime") {
		let { windowId: r, action: i } = t;
		e.runtimes[r] || (e.runtimes[r] = { ...lr });
		let a = vr(e.runtimes[r], i, n);
		return a ? a.map((e) => ({
			tag: "runtime",
			windowId: r,
			action: e
		})) : null;
	}
	if (t.tag === "theme") switch (t.action.tag) {
		case "load": return n.loadTheme().map((e) => ({
			tag: "theme",
			action: {
				tag: "loaded",
				theme: e
			}
		}));
		case "loaded": return e.theme = t.action.theme, n.applyTheme(t.action.theme);
		case "toggle": return e.theme = e.theme === "dark" ? "light" : "dark", n.applyTheme(e.theme);
	}
	if (t.tag === "inlineDiagram") {
		let { action: r } = t;
		switch (r.tag) {
			case "request": return e.inlineDiagrams[r.key]?.loading ? null : (e.inlineDiagrams[r.key] = {
				svg: null,
				loading: !0,
				error: null
			}, n.getDiagram(r.kind, r.params).map((e) => ({
				tag: "inlineDiagram",
				action: {
					tag: "loaded",
					key: r.key,
					svg: e
				}
			})).catch((e) => ({
				tag: "inlineDiagram",
				action: {
					tag: "error",
					key: r.key,
					error: String(e)
				}
			})));
			case "loaded": return e.inlineDiagrams[r.key] = {
				svg: r.svg,
				loading: !1,
				error: null
			}, null;
			case "error": return e.inlineDiagrams[r.key] = {
				svg: null,
				loading: !1,
				error: r.error
			}, null;
		}
	}
	if (t.tag === "launch" && t.action.tag === "window-ast-loaded") {
		let { windowName: r, ast: i } = t.action, a = `${r}-${Date.now()}`, o = Jr(e, t, n), s = { ...e.launch.globals }, c = n.getObjectLayout(r).map((e) => ({
			tag: "runtime",
			windowId: a,
			action: {
				tag: "layout-loaded",
				layout: e
			}
		})).catch(() => ({
			tag: "runtime",
			windowId: a,
			action: {
				tag: "layout-loaded",
				layout: null
			}
		})), l = en.merge(en.send({
			tag: "windowManager",
			action: {
				tag: "open-window",
				id: a,
				title: `${r}`,
				runtimeWindowName: r
			}
		}), en.send({
			tag: "runtime",
			windowId: a,
			action: {
				tag: "set-ast",
				ast: i
			}
		}), en.send({
			tag: "runtime",
			windowId: a,
			action: {
				tag: "run-event",
				owner: r,
				event: "open",
				globals: s
			}
		}), c);
		return o ? en.merge(o, l) : l;
	}
	return Jr(e, t, n);
}
//#endregion
//#region src/features/app/api-client.ts
function Xr(e) {
	let t = new URLSearchParams();
	for (let [n, r] of Object.entries(e)) r !== "" && r != null && t.set(n, String(r));
	return t.toString();
}
async function Zr(e) {
	let t = await fetch(e);
	if (!t.ok) throw Error(`API ${t.status}`);
	return t.json();
}
async function Qr(e, t) {
	let n = await fetch(e, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(t)
	});
	if (!n.ok) throw Error(`API ${n.status}`);
	return n.json();
}
function $r(e) {
	let t = (e) => en.fromPromise(e);
	return {
		getStats: () => t(() => e.getStats()),
		getObjects: (n) => t(() => e.getObjects(n)),
		getObject: (n) => t(() => e.getObject(n)),
		getObjectSource: (n) => t(() => e.getObjectSource(n)),
		getAllObjects: () => t(() => e.getAllObjects()),
		getProcedure: (n, r) => t(() => e.getProcedure(n, r)),
		getProcedures: () => t(() => e.getProcedures()),
		search: (n) => t(() => e.search(n)),
		getDW: (n) => t(() => e.getDW(n)),
		getDwLayout: (n) => t(() => e.getDwLayout(n)),
		getObjectAst: (n) => t(() => e.getObjectAst(n)),
		getObjectLayout: (n) => t(() => e.getObjectLayout(n)),
		getDiagram: (n, r) => t(() => e.getDiagram(n, r)),
		getQueries: () => t(() => e.getQueries()),
		runQuery: (n, r) => t(() => e.runQuery(n, r)),
		runSql: (n) => t(() => e.runSql(n)),
		getExploreTree: () => t(() => e.getExploreTree()),
		getExploreProcedure: (n, r) => t(() => e.getExploreProcedure(n, r)),
		getExploreDatawindow: (n) => t(() => e.getExploreDatawindow(n)),
		getTables: () => t(() => e.getTables()),
		getTableDetail: (n) => t(() => e.getTableDetail(n)),
		getErrors: (n) => t(() => e.getErrors(n)),
		getDwQueries: () => t(() => e.getDwQueries()),
		executeSql: (n, r) => t(() => e.executeSql(n, r)),
		loadTheme: () => {
			let e = localStorage.getItem("pb-theme"), t = e === "light" || e === "dark" ? e : "dark";
			return en.send(t);
		},
		applyTheme: (e) => (localStorage.setItem("pb-theme", e), document.documentElement.setAttribute("data-theme", e), en.none()),
		navigate: (e) => en.none(),
		pushUrl: (e) => {
			e !== window.location.pathname + window.location.search && history.pushState({}, "", e);
		}
	};
}
function ei() {
	return {
		async getStats() {
			return Zr("/api/stats");
		},
		async getObjects(e) {
			return Zr("/api/objects?" + Xr(e));
		},
		async getObject(e) {
			return Zr("/api/objects/" + encodeURIComponent(e));
		},
		async getObjectSource(e) {
			return Zr("/api/objects/" + encodeURIComponent(e) + "/source");
		},
		async getAllObjects() {
			return Zr("/api/objects?limit=500");
		},
		async getProcedure(e, t) {
			return Zr(`/api/procedures/${encodeURIComponent(e)}/${encodeURIComponent(t)}`);
		},
		async getProcedures() {
			return Zr("/api/procedures");
		},
		async search(e) {
			return Zr("/api/search?q=" + encodeURIComponent(e));
		},
		async getDW(e) {
			return Zr("/api/datawindow/" + encodeURIComponent(e));
		},
		async getDwLayout(e) {
			return Zr("/api/objects/" + encodeURIComponent(e) + "/dw");
		},
		async getObjectAst(e) {
			return Zr("/api/objects/" + encodeURIComponent(e) + "/ast");
		},
		async getObjectLayout(e) {
			return Zr("/api/objects/" + encodeURIComponent(e) + "/layout");
		},
		async getDiagram(e, t) {
			let n = await fetch(`/api/diagram/${e}?` + Xr(t));
			if (!n.ok) throw Error(`HTTP ${n.status}`);
			return n.text();
		},
		async getQueries() {
			return Zr("/api/queries");
		},
		async runQuery(e, t) {
			return Zr(`/api/queries/${e}/run?` + Xr(t));
		},
		async runSql(e) {
			let t = await fetch("/api/queries/run-sql", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ sql: e })
			});
			if (!t.ok) throw Error(await t.text().then((e) => {
				try {
					return JSON.parse(e).detail;
				} catch {
					return `API ${t.status}`;
				}
			}));
			return t.json();
		},
		async getExploreTree() {
			return Zr("/api/explore/tree");
		},
		async getExploreProcedure(e, t) {
			return Zr(`/api/explore/procedure/${encodeURIComponent(e)}/${encodeURIComponent(t)}`);
		},
		async getExploreDatawindow(e) {
			return Zr(`/api/datawindow/${encodeURIComponent(e)}`);
		},
		async getTables() {
			return Zr("/api/tables");
		},
		async getTableDetail(e) {
			return Zr(`/api/tables/${encodeURIComponent(e)}`);
		},
		async getErrors(e) {
			return Zr("/api/errors?" + Xr({
				kind: e.kind ?? "",
				q: e.q ?? "",
				limit: e.limit ?? 200,
				offset: e.offset ?? 0
			}));
		},
		async getDwQueries() {
			return Zr("/api/runtime/dw-queries");
		},
		async executeSql(e, t) {
			return Qr("/api/sql/execute", {
				sql: e,
				params: t
			});
		}
	};
}
//#endregion
//#region node_modules/.pnpm/lucide-solid@1.21.0_solid-js@1.9.13/node_modules/lucide-solid/dist/source/defaultAttributes.jsx
var ti = {
	xmlns: "http://www.w3.org/2000/svg",
	width: 24,
	height: 24,
	viewBox: "0 0 24 24",
	fill: "none",
	stroke: "currentColor",
	"stroke-width": 2,
	"stroke-linecap": "round",
	"stroke-linejoin": "round"
}, ni = de({
	size: 24,
	color: "currentColor",
	strokeWidth: 2,
	absoluteStrokeWidth: !1,
	class: ""
}), ri = /*#__PURE__*/ W("<svg>"), ii = (e) => {
	for (let t in e) if (t.startsWith("aria-") || t === "role" || t === "title") return !0;
	return !1;
}, ai = (...e) => e.filter((e, t, n) => !!e && e.trim() !== "" && n.indexOf(e) === t).join(" ").trim(), oi = (e) => e.replace(/^([A-Z])|[\s-_]+(\w)/g, (e, t, n) => n ? n.toUpperCase() : t.toLowerCase()), si = (e) => e.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase(), ci = (e) => {
	let t = oi(e);
	return t.charAt(0).toUpperCase() + t.slice(1);
}, Q = (e) => {
	let [t, n] = B(e, [
		"color",
		"size",
		"strokeWidth",
		"children",
		"class",
		"name",
		"iconNode",
		"absoluteStrokeWidth"
	]), r = fe(ni);
	return (() => {
		var e = ri();
		return lt(e, z(ti, {
			get width() {
				return t.size ?? r.size ?? ti.width;
			},
			get height() {
				return t.size ?? r.size ?? ti.height;
			},
			get stroke() {
				return t.color ?? r.color ?? ti.stroke;
			},
			get "stroke-width"() {
				return U(() => (t.absoluteStrokeWidth ?? r.absoluteStrokeWidth) === !0)() ? Number(t.strokeWidth ?? r.strokeWidth ?? ti["stroke-width"]) * 24 / Number(t.size ?? r.size) : Number(t.strokeWidth ?? r.strokeWidth ?? ti["stroke-width"]);
			},
			get class() {
				return ai("lucide", "lucide-icon", r.class, ...t.name == null ? [] : [`lucide-${si(ci(t.name))}`, `lucide-${si(t.name)}`], t.class);
			},
			get "aria-hidden"() {
				return !t.children && !ii(n) ? "true" : void 0;
			}
		}, n), !0, !0), X(e, R(V, {
			get each() {
				return t.iconNode;
			},
			children: ([e, t]) => R(Dt, z({ component: e }, t))
		})), e;
	})();
}, li = [["path", {
	d: "m12 19-7-7 7-7",
	key: "1l729n"
}], ["path", {
	d: "M19 12H5",
	key: "x3x0zl"
}]], ui = (e) => R(Q, z(e, {
	iconNode: li,
	name: "arrow-left"
})), di = [["path", {
	d: "M5 12h14",
	key: "1ays0h"
}], ["path", {
	d: "m12 5 7 7-7 7",
	key: "xquz4c"
}]], fi = (e) => R(Q, z(e, {
	iconNode: di,
	name: "arrow-right"
})), pi = [
	["path", {
		d: "m21 16-4 4-4-4",
		key: "f6ql7i"
	}],
	["path", {
		d: "M17 20V4",
		key: "1ejh1v"
	}],
	["path", {
		d: "m3 8 4-4 4 4",
		key: "11wl7u"
	}],
	["path", {
		d: "M7 4v16",
		key: "1glfcx"
	}]
], mi = (e) => R(Q, z(e, {
	iconNode: pi,
	name: "arrow-up-down"
})), hi = [
	["path", {
		d: "M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z",
		key: "hh9hay"
	}],
	["path", {
		d: "m3.3 7 8.7 5 8.7-5",
		key: "g66t2b"
	}],
	["path", {
		d: "M12 22V12",
		key: "d0xqtd"
	}]
], gi = (e) => R(Q, z(e, {
	iconNode: hi,
	name: "box"
})), _i = [
	["path", {
		d: "M5 21v-6",
		key: "1hz6c0"
	}],
	["path", {
		d: "M12 21V3",
		key: "1lcnhd"
	}],
	["path", {
		d: "M19 21V9",
		key: "unv183"
	}]
], vi = (e) => R(Q, z(e, {
	iconNode: _i,
	name: "chart-no-axes-column"
})), yi = [["path", {
	d: "m6 9 6 6 6-6",
	key: "qrunsl"
}]], bi = (e) => R(Q, z(e, {
	iconNode: yi,
	name: "chevron-down"
})), xi = [["path", {
	d: "m15 18-6-6 6-6",
	key: "1wnfg3"
}]], Si = (e) => R(Q, z(e, {
	iconNode: xi,
	name: "chevron-left"
})), Ci = [["path", {
	d: "m9 18 6-6-6-6",
	key: "mthhwq"
}]], wi = (e) => R(Q, z(e, {
	iconNode: Ci,
	name: "chevron-right"
})), Ti = [["path", {
	d: "m18 15-6-6-6 6",
	key: "153udz"
}]], Ei = (e) => R(Q, z(e, {
	iconNode: Ti,
	name: "chevron-up"
})), Di = [
	["circle", {
		cx: "12",
		cy: "12",
		r: "10",
		key: "1mglay"
	}],
	["path", {
		d: "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3",
		key: "1u773s"
	}],
	["path", {
		d: "M12 17h.01",
		key: "p32p05"
	}]
], Oi = (e) => R(Q, z(e, {
	iconNode: Di,
	name: "circle-question-mark"
})), ki = [["circle", {
	cx: "12",
	cy: "12",
	r: "10",
	key: "1mglay"
}], ["path", {
	d: "M12 6v6l4 2",
	key: "mmk7yg"
}]], Ai = (e) => R(Q, z(e, {
	iconNode: ki,
	name: "clock"
})), ji = [
	["path", {
		d: "m18 16 4-4-4-4",
		key: "1inbqp"
	}],
	["path", {
		d: "m6 8-4 4 4 4",
		key: "15zrgr"
	}],
	["path", {
		d: "m14.5 4-5 16",
		key: "e7oirm"
	}]
], Mi = (e) => R(Q, z(e, {
	iconNode: ji,
	name: "code-xml"
})), Ni = [
	["ellipse", {
		cx: "12",
		cy: "5",
		rx: "9",
		ry: "3",
		key: "msslwz"
	}],
	["path", {
		d: "M3 5V19A9 3 0 0 0 21 19V5",
		key: "1wlel7"
	}],
	["path", {
		d: "M3 12A9 3 0 0 0 21 12",
		key: "mv7ke4"
	}]
], Pi = (e) => R(Q, z(e, {
	iconNode: Ni,
	name: "database"
})), Fi = [
	["path", {
		d: "M20 10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-2.5a1 1 0 0 1-.8-.4l-.9-1.2A1 1 0 0 0 15 3h-2a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1Z",
		key: "hod4my"
	}],
	["path", {
		d: "M20 21a1 1 0 0 0 1-1v-3a1 1 0 0 0-1-1h-2.9a1 1 0 0 1-.88-.55l-.42-.85a1 1 0 0 0-.92-.6H13a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1Z",
		key: "w4yl2u"
	}],
	["path", {
		d: "M3 5a2 2 0 0 0 2 2h3",
		key: "f2jnh7"
	}],
	["path", {
		d: "M3 3v13a2 2 0 0 0 2 2h3",
		key: "k8epm1"
	}]
], Ii = (e) => R(Q, z(e, {
	iconNode: Fi,
	name: "folder-tree"
})), Li = [
	["rect", {
		width: "18",
		height: "18",
		x: "3",
		y: "3",
		rx: "2",
		key: "afitv7"
	}],
	["path", {
		d: "M3 9h18",
		key: "1pudct"
	}],
	["path", {
		d: "M3 15h18",
		key: "5xshup"
	}],
	["path", {
		d: "M9 3v18",
		key: "fh3hqa"
	}],
	["path", {
		d: "M15 3v18",
		key: "14nvp0"
	}]
], Ri = (e) => R(Q, z(e, {
	iconNode: Li,
	name: "grid-3x3"
})), zi = [
	["path", {
		d: "M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z",
		key: "zw3jo"
	}],
	["path", {
		d: "M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12",
		key: "1wduqc"
	}],
	["path", {
		d: "M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17",
		key: "kqbvx6"
	}]
], Bi = (e) => R(Q, z(e, {
	iconNode: zi,
	name: "layers"
})), Vi = [
	["rect", {
		width: "7",
		height: "9",
		x: "3",
		y: "3",
		rx: "1",
		key: "10lvy0"
	}],
	["rect", {
		width: "7",
		height: "5",
		x: "14",
		y: "3",
		rx: "1",
		key: "16une8"
	}],
	["rect", {
		width: "7",
		height: "9",
		x: "14",
		y: "12",
		rx: "1",
		key: "1hutg5"
	}],
	["rect", {
		width: "7",
		height: "5",
		x: "3",
		y: "16",
		rx: "1",
		key: "ldoo1y"
	}]
], Hi = (e) => R(Q, z(e, {
	iconNode: Vi,
	name: "layout-dashboard"
})), Ui = [
	["rect", {
		width: "7",
		height: "7",
		x: "3",
		y: "3",
		rx: "1",
		key: "1g98yp"
	}],
	["rect", {
		width: "7",
		height: "7",
		x: "3",
		y: "14",
		rx: "1",
		key: "1bb6yr"
	}],
	["path", {
		d: "M14 4h7",
		key: "3xa0d5"
	}],
	["path", {
		d: "M14 9h7",
		key: "1icrd9"
	}],
	["path", {
		d: "M14 15h7",
		key: "1mj8o2"
	}],
	["path", {
		d: "M14 20h7",
		key: "11slyb"
	}]
], Wi = (e) => R(Q, z(e, {
	iconNode: Ui,
	name: "layout-list"
})), Gi = [
	["path", {
		d: "M3 5h.01",
		key: "18ugdj"
	}],
	["path", {
		d: "M3 12h.01",
		key: "nlz23k"
	}],
	["path", {
		d: "M3 19h.01",
		key: "noohij"
	}],
	["path", {
		d: "M8 5h13",
		key: "1pao27"
	}],
	["path", {
		d: "M8 12h13",
		key: "1za7za"
	}],
	["path", {
		d: "M8 19h13",
		key: "m83p4d"
	}]
], Ki = (e) => R(Q, z(e, {
	iconNode: Gi,
	name: "list"
})), qi = [
	["path", {
		d: "M15 3h6v6",
		key: "1q9fwt"
	}],
	["path", {
		d: "m21 3-7 7",
		key: "1l2asr"
	}],
	["path", {
		d: "m3 21 7-7",
		key: "tjx5ai"
	}],
	["path", {
		d: "M9 21H3v-6",
		key: "wtvkvv"
	}]
], Ji = (e) => R(Q, z(e, {
	iconNode: qi,
	name: "maximize-2"
})), Yi = [["path", {
	d: "M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z",
	key: "18887p"
}]], Xi = (e) => R(Q, z(e, {
	iconNode: Yi,
	name: "message-square"
})), Zi = [
	["path", {
		d: "m14 10 7-7",
		key: "oa77jy"
	}],
	["path", {
		d: "M20 10h-6V4",
		key: "mjg0md"
	}],
	["path", {
		d: "m3 21 7-7",
		key: "tjx5ai"
	}],
	["path", {
		d: "M4 14h6v6",
		key: "rmj7iw"
	}]
], Qi = (e) => R(Q, z(e, {
	iconNode: Zi,
	name: "minimize-2"
})), $i = [["path", {
	d: "M5 12h14",
	key: "1ays0h"
}]], ea = (e) => R(Q, z(e, {
	iconNode: $i,
	name: "minus"
})), ta = [["path", {
	d: "M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401",
	key: "kfwtm"
}]], na = (e) => R(Q, z(e, {
	iconNode: ta,
	name: "moon"
})), ra = [
	["path", {
		d: "M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z",
		key: "1a0edw"
	}],
	["path", {
		d: "M12 22V12",
		key: "d0xqtd"
	}],
	["polyline", {
		points: "3.29 7 12 12 20.71 7",
		key: "ousv84"
	}],
	["path", {
		d: "m7.5 4.27 9 5.15",
		key: "1c824w"
	}]
], ia = (e) => R(Q, z(e, {
	iconNode: ra,
	name: "package"
})), aa = [["path", {
	d: "M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z",
	key: "10ikf1"
}]], oa = (e) => R(Q, z(e, {
	iconNode: aa,
	name: "play"
})), sa = [["path", {
	d: "m21 21-4.34-4.34",
	key: "14j7rj"
}], ["circle", {
	cx: "11",
	cy: "11",
	r: "8",
	key: "4ej97u"
}]], ca = (e) => R(Q, z(e, {
	iconNode: sa,
	name: "search"
})), la = [
	["circle", {
		cx: "12",
		cy: "12",
		r: "4",
		key: "4exip2"
	}],
	["path", {
		d: "M12 2v2",
		key: "tus03m"
	}],
	["path", {
		d: "M12 20v2",
		key: "1lh1kg"
	}],
	["path", {
		d: "m4.93 4.93 1.41 1.41",
		key: "149t6j"
	}],
	["path", {
		d: "m17.66 17.66 1.41 1.41",
		key: "ptbguv"
	}],
	["path", {
		d: "M2 12h2",
		key: "1t8f8n"
	}],
	["path", {
		d: "M20 12h2",
		key: "1q8mjw"
	}],
	["path", {
		d: "m6.34 17.66-1.41 1.41",
		key: "1m8zz5"
	}],
	["path", {
		d: "m19.07 4.93-1.41 1.41",
		key: "1shlcs"
	}]
], ua = (e) => R(Q, z(e, {
	iconNode: la,
	name: "sun"
})), da = [
	["path", {
		d: "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3",
		key: "wmoenq"
	}],
	["path", {
		d: "M12 9v4",
		key: "juzpu7"
	}],
	["path", {
		d: "M12 17h.01",
		key: "p32p05"
	}]
], fa = (e) => R(Q, z(e, {
	iconNode: da,
	name: "triangle-alert"
})), pa = [["path", {
	d: "M18 6 6 18",
	key: "1bl5f8"
}], ["path", {
	d: "m6 6 12 12",
	key: "d8bk6v"
}]], ma = (e) => R(Q, z(e, {
	iconNode: pa,
	name: "x"
})), ha = de();
function ga() {
	let e = fe(ha);
	if (!e) throw Error("useExploreStore called outside Explore");
	return e;
}
//#endregion
//#region src/components/layout/BreadcrumbBar.tsx
var _a = /*#__PURE__*/ W("<span class=bc-sep aria-hidden=true>›"), va = /*#__PURE__*/ W("<button class=\"bc-segment bc-link\"><span class=bc-icon aria-hidden=true></span><span class=bc-label>"), ya = /*#__PURE__*/ W("<span class=\"bc-segment bc-current\"aria-current=page><span class=bc-icon aria-hidden=true></span><span class=bc-label>"), ba = /*#__PURE__*/ W("<nav class=breadcrumb-bar aria-label=Breadcrumb>"), xa = /*#__PURE__*/ W("<div class=bc-dropdown role=list>"), Sa = /*#__PURE__*/ W("<div class=bc-ellipsis-wrap><button class=\"bc-segment bc-ellipsis\"aria-label=\"Show hidden breadcrumb segments\">…"), Ca = /*#__PURE__*/ W("<button role=listitem class=bc-dropdown-item><span class=bc-icon aria-hidden=true></span><span class=bc-label>"), wa = {
	library: Hi,
	object: gi,
	procedure: Mi,
	datawindow: Ri,
	table: Pi,
	ask: Xi,
	analysis: vi,
	list: Ki,
	window: ia
};
function Ta(e) {
	return wa[e] ?? gi;
}
function Ea(e) {
	if (e.length <= 5) return e.map((t, n) => ({
		kind: "crumb",
		crumb: t,
		isLast: n === e.length - 1
	}));
	let t = e.slice(0, 2).map((e) => ({
		kind: "crumb",
		crumb: e,
		isLast: !1
	})), n = e.slice(2, e.length - 2), r = e.slice(-2).map((e, t) => ({
		kind: "crumb",
		crumb: e,
		isLast: t === 1
	}));
	return [
		...t,
		{
			kind: "ellipsis",
			hidden: n
		},
		...r
	];
}
function Da() {
	return _a();
}
function Oa(e) {
	return R(Dt, {
		get component() {
			return Ta(e.key);
		},
		size: 13
	});
}
function ka(e) {
	let t = e.store.getState(), n = () => t().nav.crumbs;
	function r(t) {
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: t
			}
		});
	}
	function i(e, t) {
		let n = t === 0;
		return e.kind === "ellipsis" ? R(Aa, {
			get hidden() {
				return e.hidden;
			},
			navigate: r,
			showSep: !n
		}) : [R(H, {
			when: !n,
			get children() {
				return R(Da, {});
			}
		}), R(H, {
			get when() {
				return !e.isLast;
			},
			get fallback() {
				return (() => {
					var t = ya(), n = t.firstChild, r = n.nextSibling;
					return X(n, R(Oa, { get key() {
						return e.crumb.icon;
					} })), X(r, () => e.crumb.label), N(() => K(t, "aria-label", e.crumb.label)), t;
				})();
			},
			get children() {
				var t = va(), n = t.firstChild, i = n.nextSibling;
				return t.$$click = () => r(e.crumb.route), X(n, R(Oa, { get key() {
					return e.crumb.icon;
				} })), X(i, () => e.crumb.label), N(() => K(t, "aria-label", `Navigate to ${e.crumb.label}`)), t;
			}
		})];
	}
	let a = () => Ea(n());
	return (() => {
		var e = ba();
		return X(e, R(V, {
			get each() {
				return a();
			},
			children: (e, t) => i(e, t())
		})), e;
	})();
}
function Aa(e) {
	let [t, n] = j(!1);
	return [
		R(H, {
			get when() {
				return e.showSep;
			},
			get children() {
				return R(Da, {});
			}
		}),
		(() => {
			var r = Sa(), i = r.firstChild;
			return r.addEventListener("mouseleave", () => n(!1)), r.addEventListener("mouseenter", () => n(!0)), i.addEventListener("blur", () => n(!1)), i.addEventListener("focus", () => n(!0)), X(r, R(H, {
				get when() {
					return t();
				},
				get children() {
					var t = xa();
					return X(t, R(V, {
						get each() {
							return e.hidden;
						},
						children: (t) => (() => {
							var r = Ca(), i = r.firstChild, a = i.nextSibling;
							return r.$$click = () => {
								n(!1), e.navigate(t.route);
							}, X(i, R(Oa, { get key() {
								return t.icon;
							} })), X(a, () => t.label), N(() => K(r, "aria-label", `Navigate to ${t.label}`)), r;
						})()
					})), t;
				}
			}), null), N(() => K(i, "aria-expanded", t())), r;
		})(),
		R(Da, {})
	];
}
G(["click"]);
//#endregion
//#region src/features/explore/TreeNode.tsx
var ja = /*#__PURE__*/ W("<div class=tree-children>"), Ma = /*#__PURE__*/ W("<div><div><span class=tree-name>"), Na = /*#__PURE__*/ W("<span class=tree-chevron>"), Pa = /*#__PURE__*/ W("<span class=tree-icon>"), Fa = /*#__PURE__*/ W("<span>"), Ia = /*#__PURE__*/ W("<span class=tree-summary>");
function La(e) {
	let t = ga(), n = t.getState(), r = () => n().explore.expandedNodes.has(e.nodeId), i = pe(() => e.children), a = () => !!i();
	function o() {
		e.onClick?.(), a() && t.dispatch({
			tag: "explore",
			action: {
				tag: "toggle",
				nodeId: e.nodeId
			}
		});
	}
	return (() => {
		var t = Ma(), n = t.firstChild, s = n.firstChild;
		return n.$$click = o, X(n, (() => {
			var e = U(() => !!a());
			return () => e() && (() => {
				var e = Na();
				return X(e, (() => {
					var e = U(() => !!r());
					return () => e() ? R(bi, { size: 12 }) : R(wi, { size: 12 });
				})()), e;
			})();
		})(), s), X(n, (() => {
			var t = U(() => !!e.icon);
			return () => t() && (() => {
				var t = Pa();
				return X(t, R(Dt, {
					get component() {
						return e.icon;
					},
					size: 14
				})), t;
			})();
		})(), s), X(n, (() => {
			var t = U(() => !!e.badge);
			return () => t() && (() => {
				var t = Fa();
				return X(t, () => e.badge.text), N(() => q(t, `badge ${e.badge.cls}`)), t;
			})();
		})(), s), X(s, () => e.name), X(n, (() => {
			var t = U(() => !!e.summary);
			return () => t() && (() => {
				var t = Ia();
				return X(t, () => e.summary), t;
			})();
		})(), null), X(t, R(H, {
			get when() {
				return U(() => !!r())() && a();
			},
			get children() {
				var e = ja();
				return X(e, i), e;
			}
		}), null), N((r) => {
			var i = `tree-node ${e.class ?? ""}`, a = `${e.depth * 14}px`, o = `tree-node-row clickable${e.selected ? " selected" : ""}`;
			return i !== r.e && q(t, r.e = i), a !== r.t && Y(t, "padding-left", r.t = a), o !== r.a && q(n, r.a = o), r;
		}, {
			e: void 0,
			t: void 0,
			a: void 0
		}), t;
	})();
}
G(["click"]);
//#endregion
//#region src/utils/format.ts
function Ra(e) {
	return {
		function: "badge-func",
		subroutine: "badge-sub",
		event: "badge-event",
		on: "badge-on"
	}[e] ?? "badge-func";
}
function za(e) {
	return e ? e.replace(/\\/g, "/").split("/").slice(-2).join("/") : "";
}
//#endregion
//#region src/features/explore/TreeNodes.tsx
function Ba(e) {
	return `lib:${e}`;
}
function Va(e, t) {
	return `obj:${e}:${t}`;
}
function Ha(e, t) {
	return `proc:${e}:${t}`;
}
var Ua = {
	powerscript: "badge-ps",
	datawindow: "badge-dw",
	project: "badge-proj"
};
function Wa(e) {
	return Ua[e] ?? "badge-proj";
}
function Ga(e) {
	let t = ga(), n = t.getState(), r = () => Ha(e.objName, e.proc.name), i = () => {
		let t = n().nav.route;
		return t.view === "procedureDetail" && t.proc === e.proc.name && t.name === e.objName;
	}, a = F(() => e.proc.cyclomatic == null ? "" : `cc=${e.proc.cyclomatic}`);
	return R(La, {
		get nodeId() {
			return r();
		},
		get depth() {
			return e.depth;
		},
		get badge() {
			return {
				text: e.proc.proc_type,
				cls: Ra(e.proc.proc_type)
			};
		},
		get name() {
			return e.proc.name;
		},
		get summary() {
			return a();
		},
		get selected() {
			return i();
		},
		onClick: () => {
			t.dispatch({
				tag: "objects",
				action: {
					tag: "proc-select",
					objectName: e.objName,
					procName: e.proc.name
				}
			});
		}
	});
}
function Ka(e) {
	let t = ga(), n = t.getState(), r = () => Va(e.lib, e.obj.name), i = () => e.obj.kind === "datawindow", a = () => {
		let t = n().nav.route;
		return t.view === "objectDetail" && t.name === e.obj.name;
	}, o = () => n().explore.treeFilter.toLowerCase(), s = F(() => {
		let t = o();
		return t ? e.obj.procedures.filter((e) => e.name.toLowerCase().includes(t)) : e.obj.procedures;
	}), c = F(() => {
		let t = o();
		return !t || e.obj.name.toLowerCase().includes(t) ? !0 : i() ? !1 : s().length > 0;
	});
	return R(H, {
		get when() {
			return c();
		},
		get children() {
			return R(La, {
				get nodeId() {
					return r();
				},
				get depth() {
					return e.depth;
				},
				get badge() {
					return {
						text: e.obj.kind,
						cls: Wa(e.obj.kind)
					};
				},
				get name() {
					return e.obj.name;
				},
				get selected() {
					return a();
				},
				get onClick() {
					return i() ? () => t.dispatch({
						tag: "explore",
						action: {
							tag: "dw-select",
							dwName: e.obj.name,
							nodeId: r()
						}
					}) : () => t.dispatch({
						tag: "objects",
						action: {
							tag: "select",
							name: e.obj.name
						}
					});
				},
				get children() {
					return R(H, {
						get when() {
							return !i();
						},
						get children() {
							return R(V, {
								get each() {
									return s();
								},
								children: (t) => R(Ga, {
									get objName() {
										return e.obj.name;
									},
									proc: t,
									get depth() {
										return e.depth + 1;
									}
								})
							});
						}
					});
				}
			});
		}
	});
}
function qa(e) {
	let t = ga(), n = t.getState(), r = () => Ba(e.lib.name), i = () => n().explore.treeFilter.toLowerCase(), a = F(() => {
		let t = i();
		return t ? e.lib.objects.some((e) => e.name.toLowerCase().includes(t) ? !0 : e.kind === "datawindow" ? !1 : e.procedures.some((e) => e.name.toLowerCase().includes(t))) : !0;
	});
	return R(H, {
		get when() {
			return a();
		},
		get children() {
			return R(La, {
				get nodeId() {
					return r();
				},
				get depth() {
					return e.depth;
				},
				icon: ia,
				get name() {
					return e.lib.name;
				},
				get summary() {
					return `${e.lib.objects.length} objects`;
				},
				onClick: () => t.dispatch({
					tag: "nav",
					action: {
						tag: "navigate",
						route: {
							view: "libraryDetail",
							name: e.lib.name
						}
					}
				}),
				get children() {
					return R(V, {
						get each() {
							return e.lib.objects;
						},
						children: (t) => R(Ka, {
							get lib() {
								return e.lib.name;
							},
							obj: t,
							get depth() {
								return e.depth + 1;
							}
						})
					});
				}
			});
		}
	});
}
//#endregion
//#region src/components/layout/Sidebar.tsx
var Ja = /*#__PURE__*/ W("<span>P"), Ya = /*#__PURE__*/ W("<a href=#><span class=analysis-nav-label>"), Xa = /*#__PURE__*/ W("<div class=sidebar-group-body>"), Za = /*#__PURE__*/ W("<div class=sidebar-group><button class=sidebar-group-header><span class=sidebar-group-icon></span><span class=sidebar-group-label></span><span class=sidebar-group-chevron>"), Qa = /*#__PURE__*/ W("<div class=subtitle>PowerBuilder Codebase Explorer"), $a = /*#__PURE__*/ W("<button class=theme-toggle>"), eo = /*#__PURE__*/ W("<nav class=sidebar-util-nav>"), to = /*#__PURE__*/ W("<nav class=sidebar-rail><button class=sidebar-rail-icon title=\"Source Tree\"></button><button class=sidebar-rail-icon title=\"Entity Navigation\"></button><button class=sidebar-rail-icon title=\"Analysis Navigation\">"), no = /*#__PURE__*/ W("<div class=sidebar-tree-controls><button class=filter-pill>Expand All</button><button class=filter-pill>Collapse All"), ro = /*#__PURE__*/ W("<input class=explore-filter-input placeholder=Filter…>"), io = /*#__PURE__*/ W("<div class=sidebar-tree-body>"), ao = /*#__PURE__*/ W("<nav class=sidebar-entity-nav>"), oo = /*#__PURE__*/ W("<div class=sidebar-groups><div class=sidebar-section-label>Runtime</div><nav class=sidebar-entity-nav>"), so = /*#__PURE__*/ W("<aside><div class=sidebar-header><div class=sidebar-header-row><h1>pb explore</h1><button class=sidebar-collapse-btn>"), co = /*#__PURE__*/ W("<a href=#><span class=icon></span><span>"), lo = /*#__PURE__*/ W("<button>"), uo = /*#__PURE__*/ W("<div class=loading-overlay><div class=spinner></div> Loading…"), fo = /*#__PURE__*/ W("<div class=tree-empty>No data. Run <code>pb index</code> first."), po = [
	{
		label: "Objects",
		view: "objects",
		icon: gi
	},
	{
		label: "DataWindows",
		view: "datawindows",
		icon: Ri
	},
	{
		label: "Tables",
		view: "tables",
		icon: Pi
	},
	{
		label: "Procedures",
		view: "proceduresList",
		icon: Mi
	}
], mo = [
	{
		label: "Schema / ERD",
		view: "diagrams",
		phase: 1,
		gated: !1
	},
	{
		label: "Dead Code",
		view: "deadCode",
		phase: 1,
		gated: !1
	},
	{
		label: "Taint Explorer",
		view: "taintExplorer",
		phase: 3,
		gated: !0
	},
	{
		label: "Formal Reports",
		view: "formalReports",
		phase: 4,
		gated: !0
	}
], ho = [
	{
		label: "Dashboard",
		view: "dashboard",
		icon: Hi
	},
	{
		label: "Ask",
		view: "queries",
		icon: Xi
	},
	{
		label: "Search",
		view: "search",
		icon: ca
	},
	{
		label: "Diagnostics",
		view: "errors",
		icon: fa
	}
], go = [{
	label: "Launch",
	view: "launch",
	icon: oa
}], _o = {
	objects: [
		"objects",
		"objectDetail",
		"procedureDetail"
	],
	proceduresList: ["proceduresList"],
	datawindows: ["datawindows", "dwDetail"],
	tables: ["tables", "tableDetail"]
};
function vo(e, t) {
	if (e === t) return !0;
	let n = _o[e];
	return n ? n.includes(t) : !1;
}
function yo(e, t) {
	t === "proceduresList" ? e.dispatch({
		tag: "objects",
		action: { tag: "procs-list-load" }
	}) : e.dispatch({
		tag: "nav",
		action: {
			tag: "navigate",
			route: { view: t }
		}
	});
}
function bo(e) {
	let t = () => e.gated ? "phase-badge phase-badge-gated" : "phase-badge phase-badge-active";
	return (() => {
		var n = Ja();
		return n.firstChild, X(n, () => e.phase, null), N(() => q(n, t())), n;
	})();
}
function xo(e) {
	let t = () => vo(e.item.view, e.currentView), n = () => {
		let n = "sidebar-entity-link analysis-nav-item";
		return t() && (n += " active"), e.item.gated && (n += " gated"), n;
	};
	return (() => {
		var t = Ya(), r = t.firstChild;
		return t.$$click = (t) => {
			t.preventDefault(), yo(e.store, e.item.view);
		}, X(r, () => e.item.label), X(t, R(bo, {
			get phase() {
				return e.item.phase;
			},
			get gated() {
				return e.item.gated;
			}
		}), null), N((r) => {
			var i = n(), a = `${e.item.label} (P${e.item.phase}${e.item.gated ? ", phase-gated" : ""})`;
			return i !== r.e && q(t, r.e = i), a !== r.t && K(t, "aria-label", r.t = a), r;
		}, {
			e: void 0,
			t: void 0
		}), t;
	})();
}
function So(e) {
	return (() => {
		var t = Za(), n = t.firstChild, r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
		return J(n, "click", e.onToggle, !0), X(r, R(Dt, {
			get component() {
				return e.icon;
			},
			size: 15
		})), X(i, () => e.label), X(a, R(bi, {
			size: 13,
			get style() {
				return {
					transform: e.expanded ? "rotate(0deg)" : "rotate(-90deg)",
					transition: "transform 0.15s"
				};
			}
		})), X(t, R(H, {
			get when() {
				return e.expanded;
			},
			get children() {
				var t = Xa();
				return X(t, () => e.children), t;
			}
		}), null), t;
	})();
}
function Co(e) {
	let t = e.store, n = t.getState(), r = () => n().explore;
	return (() => {
		var i = so(), a = i.firstChild, o = a.firstChild.firstChild.nextSibling;
		return o.$$click = () => e.onSetCollapsed(!e.collapsed), X(o, (() => {
			var t = U(() => !!e.collapsed);
			return () => t() ? R(wi, { size: 16 }) : R(Si, { size: 16 });
		})()), X(a, R(H, {
			get when() {
				return !e.collapsed;
			},
			get children() {
				return [Qa(), (() => {
					var e = $a();
					return e.$$click = () => t.dispatch({
						tag: "theme",
						action: { tag: "toggle" }
					}), X(e, (() => {
						var e = U(() => n().theme === "dark");
						return () => e() ? R(ua, { size: 15 }) : R(na, { size: 15 });
					})()), N(() => K(e, "title", n().theme === "dark" ? "Switch to light mode" : "Switch to dark mode")), e;
				})()];
			}
		}), null), X(i, R(H, {
			get when() {
				return !e.collapsed;
			},
			get children() {
				var n = eo();
				return X(n, R(V, {
					each: ho,
					children: (n) => (() => {
						var r = co(), i = r.firstChild, a = i.nextSibling;
						return r.$$click = (e) => {
							e.preventDefault(), yo(t, n.view);
						}, X(i, R(Dt, {
							get component() {
								return n.icon;
							},
							size: 15
						})), X(a, () => n.label), N(() => q(r, `sidebar-util-link${vo(n.view, e.currentView) ? " active" : ""}`)), r;
					})()
				})), n;
			}
		}), null), X(i, R(H, {
			get when() {
				return e.collapsed;
			},
			get children() {
				var n = to(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
				return r.$$click = () => {
					e.onSetCollapsed(!1), e.sidebarGroups.sourceTree || e.onToggleGroup("sourceTree");
				}, X(r, R(Ii, { size: 16 })), i.$$click = () => {
					e.onSetCollapsed(!1), e.sidebarGroups.entityNav || e.onToggleGroup("entityNav");
				}, X(i, R(Wi, { size: 16 })), a.$$click = () => {
					e.onSetCollapsed(!1), e.sidebarGroups.analysisNav || e.onToggleGroup("analysisNav");
				}, X(a, R(vi, { size: 16 })), X(n, R(V, {
					each: ho,
					children: (n) => (() => {
						var r = lo();
						return r.$$click = () => yo(t, n.view), X(r, R(Dt, {
							get component() {
								return n.icon;
							},
							size: 16
						})), N((t) => {
							var i = `sidebar-rail-icon${vo(n.view, e.currentView) ? " active" : ""}`, a = n.label;
							return i !== t.e && q(r, t.e = i), a !== t.t && K(r, "title", t.t = a), t;
						}, {
							e: void 0,
							t: void 0
						}), r;
					})()
				}), null), X(n, R(V, {
					each: go,
					children: (n) => (() => {
						var r = lo();
						return r.$$click = () => yo(t, n.view), X(r, R(Dt, {
							get component() {
								return n.icon;
							},
							size: 16
						})), N((t) => {
							var i = `sidebar-rail-icon${vo(n.view, e.currentView) ? " active" : ""}`, a = n.label;
							return i !== t.e && q(r, t.e = i), a !== t.t && K(r, "title", t.t = a), t;
						}, {
							e: void 0,
							t: void 0
						}), r;
					})()
				}), null), n;
			}
		}), null), X(i, R(H, {
			get when() {
				return !e.collapsed;
			},
			get children() {
				var n = oo(), i = n.firstChild, a = i.nextSibling;
				return X(n, R(So, {
					label: "Source Tree",
					get expanded() {
						return e.sidebarGroups.sourceTree;
					},
					onToggle: () => e.onToggleGroup("sourceTree"),
					icon: Ii,
					get children() {
						return [
							(() => {
								var e = no(), n = e.firstChild, r = n.nextSibling;
								return n.$$click = () => t.dispatch({
									tag: "explore",
									action: { tag: "expand-all" }
								}), r.$$click = () => t.dispatch({
									tag: "explore",
									action: { tag: "collapse-all" }
								}), e;
							})(),
							(() => {
								var e = ro();
								return e.$$input = (e) => t.dispatch({
									tag: "explore",
									action: {
										tag: "filter",
										q: e.currentTarget.value
									}
								}), N(() => e.value = r().treeFilter), e;
							})(),
							(() => {
								var e = io();
								return X(e, R(H, {
									get when() {
										return !r().loading;
									},
									get fallback() {
										return uo();
									},
									get children() {
										return R(H, {
											get when() {
												return r().libraries.length > 0;
											},
											get fallback() {
												return fo();
											},
											get children() {
												return R(V, {
													get each() {
														return r().libraries;
													},
													children: (e) => R(qa, {
														lib: e,
														depth: 0
													})
												});
											}
										});
									}
								})), e;
							})()
						];
					}
				}), i), X(n, R(So, {
					label: "Entity Navigation",
					get expanded() {
						return e.sidebarGroups.entityNav;
					},
					onToggle: () => e.onToggleGroup("entityNav"),
					icon: Wi,
					get children() {
						var n = ao();
						return X(n, R(V, {
							each: po,
							children: (n) => (() => {
								var r = co(), i = r.firstChild, a = i.nextSibling;
								return r.$$click = (e) => {
									e.preventDefault(), yo(t, n.view);
								}, X(i, R(Dt, {
									get component() {
										return n.icon;
									},
									size: 15
								})), X(a, () => n.label), N(() => q(r, `sidebar-entity-link${vo(n.view, e.currentView) ? " active" : ""}`)), r;
							})()
						})), n;
					}
				}), i), X(n, R(So, {
					label: "Analysis Navigation",
					get expanded() {
						return e.sidebarGroups.analysisNav;
					},
					onToggle: () => e.onToggleGroup("analysisNav"),
					icon: vi,
					get children() {
						var n = ao();
						return X(n, R(V, {
							each: mo,
							children: (n) => R(xo, {
								item: n,
								get currentView() {
									return e.currentView;
								},
								store: t
							})
						})), n;
					}
				}), i), X(a, R(V, {
					each: go,
					children: (n) => (() => {
						var r = co(), i = r.firstChild, a = i.nextSibling;
						return r.$$click = (e) => {
							e.preventDefault(), yo(t, n.view);
						}, X(i, R(Dt, {
							get component() {
								return n.icon;
							},
							size: 15
						})), X(a, () => n.label), N(() => q(r, `sidebar-entity-link${vo(n.view, e.currentView) ? " active" : ""}`)), r;
					})()
				})), n;
			}
		}), null), N((t) => {
			var n = `sidebar${e.collapsed ? " sidebar-collapsed" : ""}`, r = e.collapsed ? "Expand sidebar" : "Collapse sidebar";
			return n !== t.e && q(i, t.e = n), r !== t.t && K(o, "title", t.t = r), t;
		}, {
			e: void 0,
			t: void 0
		}), i;
	})();
}
G(["click", "input"]);
//#endregion
//#region src/utils/hooks/useKeyboardShortcuts.ts
function wo(e) {
	ae(() => {
		let t = null, n = null;
		function r() {
			t = null, n &&= (clearTimeout(n), null);
		}
		function i(i) {
			let a = i.target;
			if (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.isContentEditable) {
				r();
				return;
			}
			if (t === "g") {
				switch (r(), i.key.toLowerCase()) {
					case "d":
						e.dispatch({
							tag: "nav",
							action: {
								tag: "navigate",
								route: { view: "dashboard" }
							}
						});
						return;
					case "a":
						e.dispatch({
							tag: "nav",
							action: {
								tag: "navigate",
								route: { view: "queries" }
							}
						});
						return;
					case "e":
						e.dispatch({
							tag: "nav",
							action: {
								tag: "navigate",
								route: { view: "errors" }
							}
						});
						return;
				}
				return;
			}
			let o = e.getState();
			switch (i.key) {
				case "/":
					i.preventDefault(), e.dispatch({
						tag: "search",
						action: { tag: "overlay-open" }
					});
					break;
				case "?":
					e.dispatch({
						tag: "explore",
						action: { tag: "help-overlay-toggle" }
					});
					break;
				case "Escape":
					o().search.overlayOpen ? e.dispatch({
						tag: "search",
						action: { tag: "overlay-close" }
					}) : o().explore.helpOverlayOpen && e.dispatch({
						tag: "explore",
						action: { tag: "help-overlay-toggle" }
					});
					break;
				case "[":
					e.dispatch({
						tag: "nav",
						action: { tag: "back" }
					});
					break;
				case "]":
					e.dispatch({
						tag: "nav",
						action: { tag: "forward" }
					});
					break;
				case "g":
					t = "g", n = setTimeout(r, 1e3);
					break;
				case "1":
					e.dispatch({
						tag: "explore",
						action: {
							tag: "sidebar-focus-group",
							group: "sourceTree"
						}
					});
					break;
				case "2":
					e.dispatch({
						tag: "explore",
						action: {
							tag: "sidebar-focus-group",
							group: "entityNav"
						}
					});
					break;
				case "3":
					e.dispatch({
						tag: "explore",
						action: {
							tag: "sidebar-focus-group",
							group: "analysisNav"
						}
					});
					break;
			}
		}
		document.addEventListener("keydown", i), L(() => {
			document.removeEventListener("keydown", i), r();
		});
	});
}
//#endregion
//#region src/components/layout/Layout.tsx
var To = /*#__PURE__*/ W("<div><div></div><div class=main-panel><div class=top-bar><div class=top-bar-actions><button class=top-bar-btn title=\"Search (press /)\"></button><button class=top-bar-btn title=\"Keyboard shortcuts (press ?)\"></button></div></div><main class=main-content>"), Eo = 180, Do = .6;
function Oo() {
	try {
		let e = localStorage.getItem("pb-sidebar-width");
		if (e) {
			let t = Number(e);
			if (t >= Eo) return t;
		}
	} catch {}
	return 280;
}
function ko(e) {
	let t = e.store.getState(), n = () => t().nav.route.view, r = () => t().explore, i = () => r().sidebarGroups, a = () => r().sidebarCollapsed, [o, s] = j(Oo()), [c, l] = j(!1), u = 0, d = 0;
	function f(e) {
		e.preventDefault(), u = e.clientX, d = o(), l(!0), document.addEventListener("pointermove", p), document.addEventListener("pointerup", m);
	}
	function p(e) {
		let t = window.innerWidth * Do;
		s(Math.min(t, Math.max(Eo, d + (e.clientX - u))));
	}
	function m() {
		l(!1), document.removeEventListener("pointermove", p), document.removeEventListener("pointerup", m);
		try {
			localStorage.setItem("pb-sidebar-width", String(o()));
		} catch {}
	}
	L(() => {
		document.removeEventListener("pointermove", p), document.removeEventListener("pointerup", m);
	});
	function h(t) {
		e.store.dispatch({
			tag: "explore",
			action: {
				tag: "sidebar-toggle-group",
				group: t
			}
		});
	}
	function g(t) {
		e.store.dispatch({
			tag: "explore",
			action: {
				tag: "sidebar-set-collapsed",
				collapsed: t
			}
		});
	}
	wo(e.store);
	let _ = () => `${a() ? 44 : o()}px`;
	return R(ha.Provider, {
		get value() {
			return e.store;
		},
		get children() {
			var t = To(), r = t.firstChild, s = r.nextSibling.firstChild, l = s.firstChild, u = l.firstChild, d = u.nextSibling, p = s.nextSibling;
			return X(t, R(Co, {
				get store() {
					return e.store;
				},
				get collapsed() {
					return a();
				},
				get sidebarGroups() {
					return i();
				},
				get currentView() {
					return n();
				},
				onToggleGroup: h,
				onSetCollapsed: g
			}), r), r.$$pointerdown = f, X(s, R(ka, { get store() {
				return e.store;
			} }), l), u.$$click = () => e.store.dispatch({
				tag: "search",
				action: { tag: "overlay-open" }
			}), X(u, R(ca, { size: 15 })), d.$$click = () => e.store.dispatch({
				tag: "explore",
				action: { tag: "help-overlay-toggle" }
			}), X(d, R(Oi, { size: 15 })), X(p, () => e.children), N((e) => {
				var n = `app-layout${a() ? " sidebar-is-collapsed" : ""}`, i = `${a() ? 44 : o()}px`, s = `resize-handle${c() ? " dragging" : ""}`, l = _();
				return n !== e.e && q(t, e.e = n), i !== e.t && Y(t, "--sidebar-w", e.t = i), s !== e.a && q(r, e.a = s), l !== e.o && Y(r, "left", e.o = l), e;
			}, {
				e: void 0,
				t: void 0,
				a: void 0,
				o: void 0
			}), t;
		}
	});
}
G(["pointerdown", "click"]);
//#endregion
//#region src/utils/entities.ts
var Ao = {
	library: Hi,
	object: gi,
	procedure: Mi,
	datawindow: Ri,
	table: Pi,
	powerscript: gi,
	project: Bi
};
function jo(e) {
	return Ao[e] ?? gi;
}
//#endregion
//#region src/utils/debounce.ts
function Mo(e, t) {
	let n;
	return ((...r) => {
		clearTimeout(n), n = setTimeout(() => e(...r), t);
	});
}
//#endregion
//#region src/components/ui/ModalShell.tsx
var No = /*#__PURE__*/ W("<div class=gs-backdrop>"), Po = /*#__PURE__*/ W("<div class=gs-panel role=dialog aria-modal=true>");
function Fo(e) {
	return R(H, {
		get when() {
			return e.open;
		},
		get children() {
			return [(() => {
				var t = No();
				return J(t, "click", e.onClose, !0), t;
			})(), (() => {
				var t = Po();
				return X(t, () => e.children), N((n) => {
					var r = e.label, i = e.width ? { "max-width": e.width } : void 0;
					return r !== n.e && K(t, "aria-label", n.e = r), n.t = ct(t, i, n.t), n;
				}, {
					e: void 0,
					t: void 0
				}), t;
			})()];
		}
	});
}
G(["click"]);
//#endregion
//#region src/components/GlobalSearch.tsx
var Io = /*#__PURE__*/ W("<div class=gs-input-row><span class=gs-input-icon aria-hidden=true></span><input class=gs-input placeholder=\"Search objects, procedures, DataWindows, tables…\"><button class=gs-close-btn aria-label=\"Close search\">×"), Lo = /*#__PURE__*/ W("<div class=gs-section><div class=gs-section-header>Recent"), Ro = /*#__PURE__*/ W("<div class=gs-loading>Searching…"), zo = /*#__PURE__*/ W("<div class=gs-empty>No results for <em>"), Bo = /*#__PURE__*/ W("<div class=gs-section><div class=gs-section-header>Objects"), Vo = /*#__PURE__*/ W("<div class=gs-section><div class=gs-section-header>Procedures"), Ho = /*#__PURE__*/ W("<div class=gs-section><div class=gs-section-header>DataWindows"), Uo = /*#__PURE__*/ W("<div class=gs-section><div class=gs-section-header>Tables"), Wo = /*#__PURE__*/ W("<div class=gs-results>"), Go = /*#__PURE__*/ W("<div class=gs-hint><kbd>Esc</kbd> to close · <kbd>/</kbd> to open"), Ko = /*#__PURE__*/ W("<button class=gs-recent-item><span class=gs-recent-icon aria-hidden=true>"), qo = /*#__PURE__*/ W("<button class=gs-result-item><span class=gs-result-icon aria-hidden=true></span><span class=gs-result-name></span><span class=gs-result-meta>"), Jo = /*#__PURE__*/ W("<button class=gs-result-item><span class=gs-result-icon aria-hidden=true></span><span class=gs-result-name></span><span class=gs-result-meta></span><span>"), Yo = /*#__PURE__*/ W("<button class=gs-result-item><span class=gs-result-icon aria-hidden=true></span><span class=gs-result-name>");
function Xo(e) {
	let t = e.store, n = t.getState(), r = () => n().search, i;
	P(() => {
		r().overlayOpen && i && i.focus();
	});
	let a = Mo((e) => {
		t.dispatch({
			tag: "search",
			action: {
				tag: "overlay-term",
				term: e
			}
		});
	}, 250);
	function o() {
		t.dispatch({
			tag: "search",
			action: { tag: "overlay-close" }
		});
	}
	function s(e) {
		e(), o();
	}
	let c = () => r().overlayResults, l = () => r().recentSearches, u = () => r().overlayTerm, d = () => {
		let e = c();
		return e ? e.objects.length + e.procedures.length + e.datawindows.length + (e.tables?.length ?? 0) > 0 : !1;
	};
	return R(Fo, {
		get open() {
			return r().overlayOpen;
		},
		onClose: o,
		label: "Search",
		get children() {
			return [
				(() => {
					var e = Io(), t = e.firstChild, n = t.nextSibling, r = n.nextSibling;
					X(t, R(ca, { size: 16 })), n.$$keydown = (e) => {
						e.key === "Escape" && o();
					}, n.$$input = (e) => a(e.currentTarget.value);
					var s = i;
					return typeof s == "function" ? ut(s, n) : i = n, r.$$click = o, N(() => n.value = u()), e;
				})(),
				R(H, {
					get when() {
						return U(() => u().length < 2)() && l().length > 0;
					},
					get children() {
						var e = Lo();
						return e.firstChild, X(e, R(V, {
							get each() {
								return l();
							},
							children: (e) => (() => {
								var n = Ko(), r = n.firstChild;
								return n.$$click = () => {
									t.dispatch({
										tag: "search",
										action: {
											tag: "overlay-term",
											term: e
										}
									});
								}, X(r, R(Ai, { size: 14 })), X(n, e, null), n;
							})()
						}), null), e;
					}
				}),
				R(H, {
					get when() {
						return r().overlayLoading;
					},
					get children() {
						return Ro();
					}
				}),
				R(H, {
					get when() {
						return U(() => !!(u().length >= 2 && !r().overlayLoading && c()))() && !d();
					},
					get children() {
						var e = zo(), t = e.firstChild.nextSibling;
						return X(t, u), e;
					}
				}),
				R(H, {
					get when() {
						return d();
					},
					get children() {
						var e = Wo();
						return X(e, R(H, {
							get when() {
								return (c()?.objects.length ?? 0) > 0;
							},
							get children() {
								var e = Bo();
								return e.firstChild, X(e, R(V, {
									get each() {
										return c().objects.slice(0, 8);
									},
									children: (e) => (() => {
										var n = qo(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
										return n.$$click = () => s(() => t.dispatch({
											tag: "objects",
											action: {
												tag: "select",
												name: e.name
											}
										})), X(r, R(Dt, {
											get component() {
												return jo(e.kind);
											},
											size: 14
										})), X(i, () => e.name), X(a, () => za(e.file)), n;
									})()
								}), null), e;
							}
						}), null), X(e, R(H, {
							get when() {
								return (c()?.procedures.length ?? 0) > 0;
							},
							get children() {
								var e = Vo();
								return e.firstChild, X(e, R(V, {
									get each() {
										return c().procedures.slice(0, 8);
									},
									children: (e) => (() => {
										var n = Jo(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.nextSibling;
										return n.$$click = () => s(() => t.dispatch({
											tag: "objects",
											action: {
												tag: "proc-select",
												objectName: e.object,
												procName: e.name
											}
										})), X(r, R(Dt, {
											get component() {
												return jo("procedure");
											},
											size: 14
										})), X(i, () => e.name), X(a, () => e.object), X(o, () => e.proc_type), N(() => q(o, `badge ${Ra(e.proc_type)}`)), n;
									})()
								}), null), e;
							}
						}), null), X(e, R(H, {
							get when() {
								return (c()?.datawindows.length ?? 0) > 0;
							},
							get children() {
								var e = Ho();
								return e.firstChild, X(e, R(V, {
									get each() {
										return c().datawindows.slice(0, 8);
									},
									children: (e) => (() => {
										var n = qo(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
										return n.$$click = () => s(() => t.dispatch({
											tag: "datawindows",
											action: {
												tag: "select",
												name: e.dw_name
											}
										})), X(r, R(Dt, {
											get component() {
												return jo("datawindow");
											},
											size: 14
										})), X(i, () => e.dw_name), X(a, () => e.control_type ?? ""), n;
									})()
								}), null), e;
							}
						}), null), X(e, R(H, {
							get when() {
								return (c()?.tables?.length ?? 0) > 0;
							},
							get children() {
								var e = Uo();
								return e.firstChild, X(e, R(V, {
									get each() {
										return c().tables.slice(0, 8);
									},
									children: (e) => (() => {
										var n = Yo(), r = n.firstChild, i = r.nextSibling;
										return n.$$click = () => s(() => t.dispatch({
											tag: "tables",
											action: {
												tag: "select",
												name: e.table_name
											}
										})), X(r, R(Dt, {
											get component() {
												return jo("table");
											},
											size: 14
										})), X(i, () => e.table_name), n;
									})()
								}), null), e;
							}
						}), null), e;
					}
				}),
				Go()
			];
		}
	});
}
G([
	"input",
	"keydown",
	"click"
]);
//#endregion
//#region src/components/layout/HelpOverlay.tsx
var Zo = /*#__PURE__*/ W("<div class=help-panel-header><h2>Keyboard Shortcuts</h2><button class=help-close-btn aria-label=Close>×"), Qo = /*#__PURE__*/ W("<table class=\"data-table help-table\"><thead><tr><th>Key</th><th>Scope</th><th>Action</th></tr></thead><tbody>"), $o = /*#__PURE__*/ W("<div class=help-panel-footer>Shortcuts are inactive when an input field is focused."), es = /*#__PURE__*/ W("<tr><td><kbd class=kbd></kbd></td><td style=color:var(--text-muted)></td><td>"), ts = [
	{
		key: "/",
		scope: "Global",
		action: "Open search overlay"
	},
	{
		key: "?",
		scope: "Global",
		action: "Show keyboard shortcuts (this panel)"
	},
	{
		key: "[",
		scope: "Navigation",
		action: "Go back one step"
	},
	{
		key: "]",
		scope: "Navigation",
		action: "Go forward one step"
	},
	{
		key: "1",
		scope: "Sidebar",
		action: "Focus Source Tree group"
	},
	{
		key: "2",
		scope: "Sidebar",
		action: "Focus Entity Navigation group"
	},
	{
		key: "3",
		scope: "Sidebar",
		action: "Focus Analysis Navigation group"
	},
	{
		key: "G then D",
		scope: "Go-to chord",
		action: "Go to Dashboard"
	},
	{
		key: "G then A",
		scope: "Go-to chord",
		action: "Go to Ask"
	},
	{
		key: "G then E",
		scope: "Go-to chord",
		action: "Go to Diagnostics"
	},
	{
		key: "T",
		scope: "Entity Detail",
		action: "Toggle Source / Analysis face"
	},
	{
		key: "Esc",
		scope: "Overlay",
		action: "Close overlay"
	}
];
function ns(e) {
	let t = e.store.getState(), n = () => t().explore.helpOverlayOpen;
	function r() {
		e.store.dispatch({
			tag: "explore",
			action: { tag: "help-overlay-toggle" }
		});
	}
	return R(Fo, {
		get open() {
			return n();
		},
		onClose: r,
		label: "Keyboard shortcuts",
		width: "480px",
		get children() {
			return [
				(() => {
					var e = Zo(), t = e.firstChild.nextSibling;
					return t.$$click = r, e;
				})(),
				(() => {
					var e = Qo(), t = e.firstChild.nextSibling;
					return X(t, R(V, {
						each: ts,
						children: (e) => (() => {
							var t = es(), n = t.firstChild, r = n.firstChild, i = n.nextSibling, a = i.nextSibling;
							return X(r, () => e.key), X(i, () => e.scope), X(a, () => e.action), t;
						})()
					})), e;
				})(),
				$o()
			];
		}
	});
}
G(["click"]);
//#endregion
//#region src/components/detail/TableChip.tsx
var rs = /*#__PURE__*/ W("<span role=button tabindex=0>⊡ ");
function is(e) {
	function t() {
		e.store.dispatch({
			tag: "tables",
			action: {
				tag: "select",
				name: e.name
			}
		});
	}
	return (() => {
		var n = rs();
		return n.firstChild, n.$$keydown = (e) => {
			(e.key === "Enter" || e.key === " ") && (e.preventDefault(), t());
		}, n.$$click = t, X(n, () => e.name, null), N(() => q(n, `table-chip table-chip-${e.size ?? "md"}`)), n;
	})();
}
G(["click", "keydown"]);
//#endregion
//#region src/components/ui/Loading.tsx
var as = /*#__PURE__*/ W("<div class=loading-overlay><div class=spinner></div> Loading...");
function os() {
	return as();
}
//#endregion
//#region src/utils/diagram.ts
var ss = new Set([
	"calls",
	"dw-tables",
	"sql-lineage",
	"table-lineage",
	"proc-tables"
]), cs = new Set([
	"heatmap",
	"inheritance",
	"dw-tables",
	"sql-lineage",
	"proc-tables"
]);
function ls(e) {
	if (!e || !e.startsWith("pb://")) return null;
	let t = e.slice(5), n = t.indexOf("#"), r = n >= 0 ? t.slice(0, n) : t, i = n >= 0 ? t.slice(n + 1) : "", a = r.indexOf("/");
	if (a < 0) return null;
	let o = r.slice(0, a), s = r.slice(a + 1);
	if ((o === "object" || o === "table") && s.length > 0) {
		let e = {};
		if (i) for (let t of i.split(",")) {
			let n = t.indexOf("=");
			n > 0 && (e[t.slice(0, n)] = t.slice(n + 1));
		}
		return {
			kind: o,
			name: s,
			meta: e
		};
	}
	return null;
}
function us(e) {
	return e.getAttribute("href") || e.getAttributeNS("http://www.w3.org/1999/xlink", "href");
}
//#endregion
//#region src/components/diagram/diagramMath.ts
var ds = .15, fs = 1.15, ps = 1e3 / 60, ms = 40, hs = .955, gs = .05;
function _s(e, t, n, r, i, a) {
	let o = Math.min(8, Math.max(ds, t * (e < 0 ? fs : 1 / fs))), s = o / t;
	return {
		scale: o,
		offsetX: i - s * (i - n),
		offsetY: a - s * (a - r)
	};
}
function vs(e, t, n) {
	return e * (1 - n) + t * n;
}
function ys(e) {
	return e.replace(/<title[^>]*>[\s\S]*?<\/title>/gi, "");
}
function bs(e, t) {
	return {
		x: e.left + e.width / 2 - t.left,
		y: e.top - t.top - 8
	};
}
function xs(e, t) {
	if (Math.abs(e) < gs && Math.abs(t) < gs) return null;
	let n = e * ps, r = t * ps, i = Math.sqrt(n * n + r * r);
	return i > ms && (n *= ms / i, r *= ms / i), {
		fx: n,
		fy: r
	};
}
function Ss(e, t, n, r, i, a) {
	let o = n, s = r;
	function c() {
		if (e *= hs, t *= hs, Math.abs(e) < gs && Math.abs(t) < gs) {
			a?.();
			return;
		}
		o += e, s += t, i(o, s), requestAnimationFrame(c);
	}
	return requestAnimationFrame(c);
}
//#endregion
//#region src/components/diagram/usePanZoom.ts
var Cs = .4, ws = 1.3;
function Ts(e) {
	let [t, n] = j(1), [r, i] = j({
		x: 0,
		y: 0
	}), [a, o] = j(!1), [s, c] = j(!1), l = 0, u = {
		x: 0,
		y: 0
	}, d = {
		x: 0,
		y: 0
	}, f = 0, p = {
		x: 0,
		y: 0
	}, m = 0, h = 0, g = null;
	function _() {
		cancelAnimationFrame(l), c(!1);
	}
	function v(e) {
		g = e, e.addEventListener("wheel", O.onWheel, { passive: !1 });
	}
	function y() {
		g?.removeEventListener("wheel", O.onWheel), g = null;
	}
	function b(a) {
		if (a.ctrlKey && a.preventDefault(), a.preventDefault(), e.dismissTooltip(), !g) return;
		let o = g.getBoundingClientRect(), s = a.clientX - o.left, c = a.clientY - o.top, { scale: l, offsetX: u, offsetY: d } = _s(a.deltaY, t(), r().x, r().y, s, c);
		i({
			x: u,
			y: d
		}), n(l);
	}
	function x(t) {
		t.button === 0 && (t.target.closest("a, button") || (cancelAnimationFrame(l), c(!1), o(!0), e.dismissTooltip(), u = {
			x: t.clientX,
			y: t.clientY
		}, d = { ...r() }, f = performance.now(), p = {
			x: t.clientX,
			y: t.clientY
		}, m = 0, h = 0));
	}
	function ee(e) {
		if (!a()) return;
		let t = performance.now(), n = t - f;
		if (n > 0) {
			let t = (e.clientX - p.x) / n, r = (e.clientY - p.y) / n;
			m = vs(m, t, Cs), h = vs(h, r, Cs);
		}
		f = t, p = {
			x: e.clientX,
			y: e.clientY
		}, i({
			x: d.x + (e.clientX - u.x),
			y: d.y + (e.clientY - u.y)
		});
	}
	function S() {
		if (!a()) return;
		o(!1), cancelAnimationFrame(l);
		let e = xs(m, h);
		if (!e) return;
		c(!0);
		let t = r();
		l = Ss(e.fx, e.fy, t.x, t.y, (e, t) => i({
			x: e,
			y: t
		}), () => c(!1));
	}
	function C() {
		a() && (o(!1), cancelAnimationFrame(l));
	}
	function w() {
		e.dismissTooltip(), n((e) => Math.min(8, e * ws));
	}
	function T() {
		e.dismissTooltip(), n((e) => Math.max(.15, e / ws));
	}
	function E() {
		e.dismissTooltip(), n(1), i({
			x: 0,
			y: 0
		});
	}
	function D(t, r, a) {
		e.dismissTooltip(), n(t), i({
			x: r,
			y: a
		});
	}
	let O = {
		onWheel: b,
		onMouseDown: x,
		onMouseMove: ee,
		onMouseUp: S,
		onMouseLeave: C
	};
	return {
		state: {
			scale: t,
			offset: r,
			dragging: a,
			momentum: s
		},
		actions: {
			zoomIn: w,
			zoomOut: T,
			resetView: E,
			setView: D,
			dismissTooltip: e.dismissTooltip
		},
		handlers: O,
		cleanup: _,
		setViewportRef: v,
		removeViewportRef: y
	};
}
//#endregion
//#region src/components/diagram/DiagramTooltip.tsx
var Es = /*#__PURE__*/ W("<div class=diagram-tooltip-meta>"), Ds = /*#__PURE__*/ W("<div class=diagram-tooltip><div class=diagram-tooltip-header><span class=diagram-tooltip-name>"), Os = /*#__PURE__*/ W("<span class=diagram-tooltip-badge>"), ks = /*#__PURE__*/ W("<div class=diagram-tooltip-actions>"), As = /*#__PURE__*/ W("<a class=diagram-tooltip-link>"), js = /*#__PURE__*/ W("<span class=diagram-tooltip-sep>&middot;");
function Ms(e) {
	return (() => {
		var t = Ds(), n = t.firstChild, r = n.firstChild;
		return J(t, "mouseout", e.onMouseOut, !0), J(t, "mouseover", e.onMouseOver, !0), X(r, () => e.name), X(n, (() => {
			var t = U(() => !!e.kind);
			return () => t() && (() => {
				var t = Os();
				return X(t, () => e.kind), t;
			})();
		})(), null), X(t, R(H, {
			get when() {
				return U(() => Object.keys(e.meta).length > 0)() && !e.kind;
			},
			get children() {
				var t = Es();
				return X(t, () => Object.entries(e.meta).map(([e, t]) => `${e}=${t}`).join(" · ")), t;
			}
		}), null), X(t, (() => {
			var t = U(() => !!(e.actions && e.actions.length > 0));
			return () => t() && (() => {
				var t = ks();
				return X(t, () => e.actions.map((e, t) => [t > 0 && js(), (() => {
					var t = As();
					return J(t, "click", e.onClick, !0), X(t, () => e.label), t;
				})()])), t;
			})();
		})(), null), N((n) => {
			var r = `${e.x}px`, i = `${e.y}px`;
			return r !== n.e && Y(t, "left", n.e = r), i !== n.t && Y(t, "top", n.t = i), n;
		}, {
			e: void 0,
			t: void 0
		}), t;
	})();
}
G([
	"mouseover",
	"mouseout",
	"click"
]);
//#endregion
//#region src/components/diagram/InlineDiagram.tsx
var Ns = /*#__PURE__*/ W("<div class=loading-overlay><div class=spinner></div> Loading diagram…"), Ps = /*#__PURE__*/ W("<div class=loading-overlay style=color:var(--red)>Diagram unavailable"), Fs = /*#__PURE__*/ W("<div><div class=diagram-toolbar><button class=icon-btn title=\"Zoom out\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M4 8h8\"stroke=currentColor stroke-width=1.5 stroke-linecap=round></path></svg></button><span class=diagram-zoom-label>%</span><button class=icon-btn title=\"Zoom in\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M8 4v8M4 8h8\"stroke=currentColor stroke-width=1.5 stroke-linecap=round></path></svg></button><button class=\"icon-btn reset-btn\"title=\"Reset zoom\">1:1</button><span class=diagram-toolbar-sep></span><button class=icon-btn title=\"Copy SVG\"></button><button class=icon-btn title=\"Download SVG\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M8 2v8m0 0l-3-3m3 3l3-3M3 12.5h10\"stroke=currentColor stroke-width=1.2 stroke-linecap=round stroke-linejoin=round></path></svg></button></div><div class=diagram-svg-wrap>"), Is = /*#__PURE__*/ W("<div>"), Ls = /*#__PURE__*/ W("<svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M3 8.5l3 3 7-7\"stroke=currentColor stroke-width=1.5 stroke-linecap=round stroke-linejoin=round>"), Rs = /*#__PURE__*/ W("<svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><rect x=5 y=5 width=8 height=8 rx=1.5 stroke=currentColor stroke-width=1.2></rect><path d=\"M3 11V3.5A.5.5 0 013.5 3H11\"stroke=currentColor stroke-width=1.2 stroke-linecap=round>");
function zs(e, t) {
	return JSON.stringify({
		kind: e,
		params: t
	});
}
function Bs(e) {
	let [t, n] = j(null), r = null, i, a = Ts({ dismissTooltip: () => n(null) }), [o, s] = j(!1);
	L(() => {
		r && clearTimeout(r), a.cleanup(), a.removeViewportRef();
	});
	function c(t, n) {
		let r = t === "object" ? "objects" : "datawindows";
		e.store.dispatch({
			tag: r,
			action: {
				tag: "select",
				name: n
			}
		});
	}
	let l = () => zs(e.kind, e.params);
	P(() => {
		let t = l();
		e.store.dispatch({
			tag: "inlineDiagram",
			action: {
				tag: "request",
				key: t,
				kind: e.kind,
				params: e.params ?? {}
			}
		});
	});
	let u = e.store.getState(), d = () => u().inlineDiagrams[l()], f = () => d()?.loading ?? !1, p = () => d()?.error ?? null, m = () => {
		let e = d()?.svg;
		return e ? ys(e) : null;
	};
	function h() {
		let e = m();
		e && navigator.clipboard.writeText(e).then(() => {
			s(!0), setTimeout(() => s(!1), 1500);
		});
	}
	function g() {
		let t = m();
		if (!t) return;
		let n = new Blob([t], { type: "image/svg+xml" }), r = URL.createObjectURL(n), i = document.createElement("a");
		i.href = r, i.download = `${e.kind}.svg`, i.click(), URL.revokeObjectURL(r);
	}
	function _(e) {
		let t = e.target.closest("a");
		if (!t) return;
		let n = ls(us(t));
		n && (e.preventDefault(), e.stopPropagation(), c(n.kind, n.name));
	}
	function v(e) {
		if (a.state.dragging() || a.state.momentum()) return;
		r &&= (clearTimeout(r), null);
		let t = e.target.closest("a");
		if (!t) return;
		let o = ls(us(t));
		if (!o) {
			n(null);
			return;
		}
		let s = i.closest(".diagram-container").getBoundingClientRect();
		n({
			...bs(t.getBoundingClientRect(), s),
			kind: o.kind,
			name: o.name,
			meta: o.meta
		});
	}
	function y(e) {
		let t = e.relatedTarget;
		t && (t.closest("a") || t.closest(".diagram-tooltip")) || (r = setTimeout(() => n(null), 150));
	}
	function b() {
		r &&= (clearTimeout(r), null);
	}
	function x(e) {
		let t = e.relatedTarget;
		t && t.closest("a") || (r = setTimeout(() => n(null), 150));
	}
	function ee(e) {
		i = e, a.setViewportRef(e);
	}
	return (() => {
		var r = Is();
		return X(r, R(H, {
			get when() {
				return f();
			},
			get children() {
				return Ns();
			}
		}), null), X(r, R(H, {
			get when() {
				return p();
			},
			get children() {
				return Ps();
			}
		}), null), X(r, R(H, {
			get when() {
				return U(() => !f() && !p())() && m();
			},
			get children() {
				var e = Fs(), t = e.firstChild, n = t.firstChild, r = n.nextSibling, i = r.firstChild, s = r.nextSibling, c = s.nextSibling, l = c.nextSibling.nextSibling, u = l.nextSibling, d = t.nextSibling;
				J(e, "mouseleave", a.handlers.onMouseLeave), J(e, "mouseup", a.handlers.onMouseUp, !0), J(e, "mousemove", a.handlers.onMouseMove, !0), J(e, "mousedown", a.handlers.onMouseDown, !0);
				var f = ee;
				return typeof f == "function" ? ut(f, e) : ee = e, J(n, "click", a.actions.zoomOut, !0), X(r, () => Math.round(a.state.scale() * 100), i), J(s, "click", a.actions.zoomIn, !0), J(c, "click", a.actions.resetView, !0), l.$$click = h, X(l, (() => {
					var e = U(() => !!o());
					return () => e() ? Ls() : Rs();
				})()), u.$$click = g, d.$$mouseout = y, d.$$mouseover = v, d.$$click = _, N((t) => {
					var n = a.state.dragging() ? "diagram-viewport grabbing" : "diagram-viewport", r = `translate(${a.state.offset().x}px, ${a.state.offset().y}px) scale(${a.state.scale()})`, i = m();
					return n !== t.e && q(e, t.e = n), r !== t.t && Y(d, "transform", t.t = r), i !== t.a && (d.innerHTML = t.a = i), t;
				}, {
					e: void 0,
					t: void 0,
					a: void 0
				}), e;
			}
		}), null), X(r, R(H, {
			get when() {
				return t();
			},
			get children() {
				return R(Ms, {
					get x() {
						return t().x;
					},
					get y() {
						return t().y;
					},
					get name() {
						return t().name;
					},
					get kind() {
						return t().meta.kind;
					},
					get meta() {
						return t().meta;
					},
					actions: [{
						label: "detail",
						onClick: () => {
							let e = t();
							n(null), c(e.kind, e.name);
						}
					}],
					onMouseOver: b,
					onMouseOut: x
				});
			}
		}), null), N(() => q(r, e.compact ? "diagram-container compact" : "diagram-container")), r;
	})();
}
G([
	"mousedown",
	"mousemove",
	"mouseup",
	"click",
	"mouseover",
	"mouseout"
]);
//#endregion
//#region src/features/dashboard/Dashboard.tsx
var Vs = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=data-table><thead><tr><th>Object</th><th>Procedure</th><th>Type</th><th>Cyclomatic</th></tr></thead><tbody>"), Hs = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell></td><td></td><td><span></span></td><td>"), Us = /*#__PURE__*/ W("<span class=\"badge badge-cc\">"), Ws = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=data-table><thead><tr><th>Object</th><th>PageRank</th><th>In</th><th>Out</th></tr></thead><tbody>"), Gs = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell></td><td></td><td></td><td>"), Ks = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Most-Referenced DB Tables</h2></div><table class=data-table><thead><tr><th>Table</th><th>DW refs</th><th>PS refs</th></tr></thead><tbody>"), qs = /*#__PURE__*/ W("<tr><td></td><td style=color:var(--text-muted)></td><td style=color:var(--text-muted)>"), Js = /*#__PURE__*/ W("<div class=phase-health-row><span class=phase-health-label></span><span class=phase-health-metric>"), Ys = /*#__PURE__*/ W("<button class=phase-health-link>View "), Xs = /*#__PURE__*/ W("<span class=\"phase-health-link muted\">—"), Zs = /*#__PURE__*/ W("<div class=metric-grid>"), Qs = /*#__PURE__*/ W("<div class=completeness-row>"), $s = /*#__PURE__*/ W("<div class=parse-error-banner><span> <!> file<!> failed to parse</span><button class=parse-error-banner-link>Diagnostics "), ec = /*#__PURE__*/ W("<div class=card style=margin-bottom:16px><div class=card-header><h2>Analysis</h2></div><div class=phase-health-rows>"), tc = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Complexity Heatmap"), nc = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Object Types</h2></div><table class=data-table><thead><tr><th>Kind</th><th>Count</th></tr></thead><tbody>"), rc = /*#__PURE__*/ W("<div class=\"metric-card linked\"role=button tabindex=0><div class=label></div><div class=value>"), ic = /*#__PURE__*/ W("<tr><td class=name-cell><span></span></td><td>");
function ac(e) {
	return (() => {
		var t = Vs(), n = t.firstChild, r = n.firstChild, i = n.nextSibling.firstChild.nextSibling;
		return X(r, () => e.title), X(i, R(V, {
			get each() {
				return e.procs;
			},
			children: (t) => (() => {
				var n = Hs(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.firstChild, s = a.nextSibling;
				return n.$$click = () => e.store.dispatch({
					tag: "objects",
					action: {
						tag: "proc-select",
						objectName: t.object,
						procName: t.name
					}
				}), X(r, () => t.object), X(i, () => t.name), X(o, () => t.proc_type), X(s, (() => {
					var e = U(() => t.cyclomatic != null);
					return () => e() ? (() => {
						var e = Us();
						return X(e, () => String(t.cyclomatic)), e;
					})() : "–";
				})()), N(() => q(o, `badge ${Ra(t.proc_type)}`)), n;
			})()
		})), t;
	})();
}
function oc(e) {
	return (() => {
		var t = Ws(), n = t.firstChild, r = n.firstChild, i = n.nextSibling.firstChild.nextSibling;
		return X(r, () => e.title), X(i, R(V, {
			get each() {
				return e.objs;
			},
			children: (t) => (() => {
				var n = Gs(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.nextSibling;
				return n.$$click = () => e.store.dispatch({
					tag: "objects",
					action: {
						tag: "select",
						name: t.object
					}
				}), X(r, () => t.object), X(i, () => String(t.pagerank)), X(a, () => String(t.in_degree)), X(o, () => String(t.out_degree)), n;
			})()
		})), t;
	})();
}
function sc(e) {
	let t = e.store.getState(), n = () => t().dashboard.topTables, r = () => n().slice(0, 10);
	return ae(() => {
		e.store.dispatch({
			tag: "dashboard",
			action: { tag: "loadTopTables" }
		});
	}), R(H, {
		get when() {
			return r().length > 0;
		},
		get children() {
			var t = Ks(), n = t.firstChild.nextSibling.firstChild.nextSibling;
			return X(n, R(V, {
				get each() {
					return r();
				},
				children: (t) => (() => {
					var n = qs(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
					return X(r, R(is, {
						get name() {
							return t.table_name;
						},
						get store() {
							return e.store;
						}
					})), X(i, () => String(t.dw_count)), X(a, () => String(t.ps_count)), n;
				})()
			})), t;
		}
	});
}
function cc(e) {
	let t = () => {
		e.route && e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: e.route
			}
		});
	};
	return (() => {
		var n = Js(), r = n.firstChild, i = r.nextSibling;
		return X(r, () => e.label), X(i, () => e.metric), X(n, (() => {
			var n = U(() => !!e.route);
			return () => n() ? (() => {
				var e = Ys();
				return e.firstChild, e.$$click = t, X(e, R(fi, {
					size: 13,
					style: { "vertical-align": "middle" }
				}), null), e;
			})() : Xs();
		})(), null), n;
	})();
}
function lc(e) {
	return e == null ? "–" : e.toLocaleString();
}
function uc(e) {
	let t = e.store, n = t.getState(), r = () => n().dashboard.stats, i = F(() => r()?.by_kind?.find((e) => e.kind === "datawindow")?.count ?? 0), a = F(() => {
		let e = r();
		return e ? `${e.files_indexed == null ? "" : `${lc(e.files_indexed)} files · `}${lc(e.objects)} objects · ${lc(e.procedures)} procedures` : "";
	}), o = F(() => {
		let e = r();
		if (!e) return null;
		let t = e.parse_error_count ?? 0, n = e.files_indexed;
		return n == null ? null : t === 0 ? `${lc(n)} files indexed · all parsed cleanly` : `${lc(n)} files indexed · ${lc(t)} file${t === 1 ? "" : "s"} with parse errors`;
	}), s = F(() => [
		{
			label: "Objects",
			value: lc(r()?.objects),
			route: { view: "objects" }
		},
		{
			label: "DataWindows",
			value: lc(i()),
			route: { view: "datawindows" }
		},
		{
			label: "DB Tables",
			value: lc(r()?.tables),
			route: { view: "tables" }
		},
		{
			label: "Procedures",
			value: lc(r()?.procedures),
			route: { view: "proceduresList" }
		},
		{
			label: "Unreferenced DWs",
			value: lc(r()?.dead_dw),
			route: {
				view: "queries",
				queryName: "dead-dw"
			}
		}
	]);
	return R(H, {
		get when() {
			return r();
		},
		get fallback() {
			return R(os, {});
		},
		get children() {
			return [
				(() => {
					var e = Zs();
					return X(e, R(V, {
						get each() {
							return s();
						},
						children: (e) => (() => {
							var n = rc(), r = n.firstChild, i = r.nextSibling;
							return n.$$keydown = (n) => n.key === "Enter" && t.dispatch({
								tag: "nav",
								action: {
									tag: "navigate",
									route: e.route
								}
							}), n.$$click = () => t.dispatch({
								tag: "nav",
								action: {
									tag: "navigate",
									route: e.route
								}
							}), X(r, () => e.label), X(i, () => e.value), n;
						})()
					})), e;
				})(),
				R(H, {
					get when() {
						return o();
					},
					get children() {
						var e = Qs();
						return X(e, o), e;
					}
				}),
				R(H, {
					get when() {
						return (r()?.parse_error_count ?? 0) > 0;
					},
					get children() {
						var e = $s(), n = e.firstChild, i = n.firstChild, a = i.nextSibling, o = a.nextSibling.nextSibling;
						o.nextSibling;
						var s = n.nextSibling;
						return s.firstChild, X(n, R(fa, {
							size: 13,
							style: { "vertical-align": "middle" }
						}), i), X(n, () => lc(r().parse_error_count), a), X(n, () => (r().parse_error_count ?? 1) === 1 ? "" : "s", o), s.$$click = () => t.dispatch({
							tag: "nav",
							action: {
								tag: "navigate",
								route: { view: "errors" }
							}
						}), X(s, R(fi, {
							size: 13,
							style: { "vertical-align": "middle" }
						}), null), e;
					}
				}),
				(() => {
					var e = ec(), n = e.firstChild.nextSibling;
					return X(n, R(cc, {
						label: "Structural",
						get metric() {
							return a();
						},
						route: { view: "deadCode" },
						store: t
					}), null), X(n, R(cc, {
						label: "Type Resolution",
						get metric() {
							return U(() => (r()?.resolved_type_count ?? 0) > 0)() ? `${lc(r().resolved_type_count)} typed vars · ${lc(r().resolved_call_count)} resolved calls` : "—";
						},
						route: null,
						store: t
					}), null), X(n, R(cc, {
						label: "Taint",
						get metric() {
							return U(() => (r()?.taint_path_count ?? 0) > 0)() ? `${lc(r().taint_path_count)} taint path${r().taint_path_count === 1 ? "" : "s"}` : "—";
						},
						route: { view: "taintExplorer" },
						store: t
					}), null), e;
				})(),
				(() => {
					var e = tc();
					return e.firstChild, X(e, R(Bs, {
						kind: "heatmap",
						store: t,
						compact: !0
					}), null), e;
				})(),
				R(H, {
					get when() {
						return U(() => !!r().by_kind)() && r().by_kind.length > 0;
					},
					get children() {
						var e = nc(), t = e.firstChild.nextSibling.firstChild.nextSibling;
						return X(t, R(V, {
							get each() {
								return r().by_kind;
							},
							children: (e) => {
								let t = e.kind === "powerscript" ? "ps" : e.kind === "datawindow" ? "dw" : "proj";
								return (() => {
									var n = ic(), r = n.firstChild, i = r.firstChild, a = r.nextSibling;
									return q(i, `badge badge-${t}`), X(i, () => e.kind), X(a, () => String(e.count)), n;
								})();
							}
						})), e;
					}
				}),
				R(H, {
					get when() {
						return U(() => !!r().top_complex)() && r().top_complex.length > 0;
					},
					get children() {
						return R(ac, {
							title: "Most Complex Procedures",
							get procs() {
								return r().top_complex;
							},
							store: t
						});
					}
				}),
				R(H, {
					get when() {
						return U(() => !!r().top_pagerank)() && r().top_pagerank.length > 0;
					},
					get children() {
						return R(oc, {
							title: "Most Important Objects (PageRank)",
							get objs() {
								return r().top_pagerank;
							},
							store: t
						});
					}
				}),
				R(sc, { store: t })
			];
		}
	});
}
G(["click", "keydown"]);
//#endregion
//#region src/components/detail/EntityCard.tsx
var dc = /*#__PURE__*/ W("<span class=entity-card-context>"), fc = /*#__PURE__*/ W("<button class=entity-card><span class=entity-card-icon aria-hidden=true></span><span class=entity-card-body><span class=entity-card-name>"), pc = {
	library: Hi,
	object: gi,
	procedure: Mi,
	datawindow: Ri,
	table: Pi
};
function mc(e) {
	return (() => {
		var t = fc(), n = t.firstChild, r = n.nextSibling, i = r.firstChild;
		return t.$$keydown = (t) => {
			t.key === "Enter" && e.onClick();
		}, J(t, "click", e.onClick, !0), X(n, R(Dt, {
			get component() {
				return pc[e.type];
			},
			size: 14
		})), X(i, () => e.name), X(r, R(H, {
			get when() {
				return e.context;
			},
			get children() {
				var t = dc();
				return X(t, () => e.context), t;
			}
		}), null), N((n) => {
			var r = e.tooltip, i = `${e.type}: ${e.name}${e.context ? ` (${e.context})` : ""}`;
			return r !== n.e && K(t, "title", n.e = r), i !== n.t && K(t, "aria-label", n.t = i), n;
		}, {
			e: void 0,
			t: void 0
		}), t;
	})();
}
G(["click", "keydown"]);
//#endregion
//#region src/components/ui/Pagination.tsx
var hc = /*#__PURE__*/ W("<div class=pagination style=display:flex;gap:8px;align-items:center;justify-content:center;margin-top:8px><button class=filter-pill>Prev</button><span style=font-size:12px;color:var(--text-muted)>–<!> of </span><button class=filter-pill>Next");
function gc(e) {
	let t = () => e.pageSize ?? 100, n = () => e.page * t();
	return (() => {
		var r = hc(), i = r.firstChild, a = i.nextSibling, o = a.firstChild, s = o.nextSibling;
		s.nextSibling;
		var c = a.nextSibling;
		return i.$$click = () => e.onPageChange(e.page - 1), X(a, () => n() + 1, o), X(a, () => Math.min(n() + t(), e.total), s), X(a, () => e.total, null), c.$$click = () => e.onPageChange(e.page + 1), N((t) => {
			var n = e.page === 0, r = e.page >= e.totalPages - 1;
			return n !== t.e && (i.disabled = t.e = n), r !== t.t && (c.disabled = t.t = r), t;
		}, {
			e: void 0,
			t: void 0
		}), r;
	})();
}
G(["click"]);
//#endregion
//#region src/utils/hooks/useListKeyboard.ts
function _c(e) {
	let t = -1;
	function n(t) {
		let n = document.querySelector(e.tableSelector);
		if (!n) return;
		n.querySelectorAll("tr.list-cursor").forEach((e) => e.classList.remove("list-cursor"));
		let r = n.querySelectorAll("tbody tr");
		r[t]?.classList.add("list-cursor"), r[t]?.scrollIntoView?.({ block: "nearest" });
	}
	ae(() => {
		function r(r) {
			let i = r.target;
			if (i.tagName === "INPUT" || i.tagName === "TEXTAREA" || i.isContentEditable) return;
			let a = e.items();
			r.key === "j" ? (r.preventDefault(), t = Math.min(t + 1, a.length - 1), n(t)) : r.key === "k" ? (r.preventDefault(), t = Math.max(t - 1, 0), n(t)) : r.key === "Enter" && t >= 0 && (r.preventDefault(), a[t]?.select());
		}
		document.addEventListener("keydown", r), L(() => document.removeEventListener("keydown", r));
	});
}
//#endregion
//#region src/features/objects/ObjectList.tsx
var vc = /*#__PURE__*/ W("<div class=search-bar><input class=search-input type=text placeholder=\"Search objects…\">"), yc = /*#__PURE__*/ W("<div class=filter-pills>"), bc = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=\"data-table object-list-table\"><thead><tr><th>Name </th><th>Kind </th><th>File</th><th>Ancestor</th></tr></thead><tbody>"), xc = /*#__PURE__*/ W("<button>"), Sc = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td><span></span></td><td style=font-size:11px;color:var(--text-muted);max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap></td><td>");
function Cc(e) {
	let t = e.store, n = t.getState(), r = () => n().objects;
	ae(() => {
		r().items.length === 0 && t.dispatch({
			tag: "objects",
			action: {
				tag: "search",
				q: r().q
			}
		});
	}), _c({
		items: () => r().items.map((e) => ({ select: () => t.dispatch({
			tag: "objects",
			action: {
				tag: "select",
				name: e.name
			}
		}) })),
		tableSelector: ".object-list-table"
	});
	let i = () => {
		let e = r().q, t = r().total;
		return e ? `Objects — ${t} results` : `Objects (${t})`;
	};
	return [
		(() => {
			var e = vc(), n = e.firstChild;
			return n.$$input = (e) => t.dispatch({
				tag: "objects",
				action: {
					tag: "search",
					q: e.currentTarget.value
				}
			}), N(() => n.value = r().q), e;
		})(),
		(() => {
			var e = yc();
			return X(e, R(V, {
				each: [
					"",
					"powerscript",
					"datawindow",
					"project",
					"pipeline"
				],
				children: (e) => (() => {
					var n = xc();
					return n.$$click = () => t.dispatch({
						tag: "objects",
						action: {
							tag: "filter-kind",
							kind: e
						}
					}), X(n, e || "All"), N(() => q(n, `filter-pill${r().kind === e ? " active" : ""}`)), n;
				})()
			})), e;
		})(),
		R(H, {
			get when() {
				return !r().loading || r().items.length > 0;
			},
			get fallback() {
				return R(os, {});
			},
			get children() {
				var e = bc(), n = e.firstChild, a = n.firstChild, o = n.nextSibling.firstChild, s = o.firstChild.firstChild;
				s.firstChild;
				var c = s.nextSibling;
				c.firstChild;
				var l = o.nextSibling;
				return X(a, i), s.$$click = () => t.dispatch({
					tag: "objects",
					action: {
						tag: "sort",
						col: "name"
					}
				}), X(s, (() => {
					var e = U(() => r().sort === "name");
					return () => e() ? U(() => r().order === "asc")() ? R(Ei, {
						size: 11,
						style: { "vertical-align": "middle" }
					}) : R(bi, {
						size: 11,
						style: { "vertical-align": "middle" }
					}) : R(mi, {
						size: 11,
						style: {
							"vertical-align": "middle",
							opacity: "0.3"
						}
					});
				})(), null), c.$$click = () => t.dispatch({
					tag: "objects",
					action: {
						tag: "sort",
						col: "kind"
					}
				}), X(c, (() => {
					var e = U(() => r().sort === "kind");
					return () => e() ? U(() => r().order === "asc")() ? R(Ei, {
						size: 11,
						style: { "vertical-align": "middle" }
					}) : R(bi, {
						size: 11,
						style: { "vertical-align": "middle" }
					}) : R(mi, {
						size: 11,
						style: {
							"vertical-align": "middle",
							opacity: "0.3"
						}
					});
				})(), null), X(l, R(V, {
					get each() {
						return r().items;
					},
					children: (e) => {
						let n = e.kind === "datawindow" ? "datawindow" : "object";
						return (() => {
							var r = Sc(), i = r.firstChild, a = i.nextSibling, o = a.firstChild, s = a.nextSibling, c = s.nextSibling;
							return X(i, R(mc, {
								type: n,
								get name() {
									return e.name;
								},
								onClick: () => t.dispatch({
									tag: "objects",
									action: {
										tag: "select",
										name: e.name
									}
								})
							})), X(o, () => e.kind), X(s, () => za(e.file)), X(c, () => e.ancestor ?? ""), N(() => q(o, `badge badge-${e.kind === "powerscript" ? "ps" : e.kind === "datawindow" ? "dw" : "proj"}`)), r;
						})();
					}
				})), X(e, R(H, {
					get when() {
						return r().total > 100;
					},
					get children() {
						return R(gc, {
							get page() {
								return Math.floor(r().offset / 100);
							},
							get totalPages() {
								return Math.ceil(r().total / 100);
							},
							get total() {
								return r().total;
							},
							pageSize: 100,
							onPageChange: (e) => t.dispatch({
								tag: "objects",
								action: {
									tag: "page",
									offset: e * 100
								}
							})
						});
					}
				}), null), N((e) => {
					var t = r().sort === "name" ? "sorted" : "", n = r().sort === "kind" ? "sorted" : "";
					return t !== e.e && q(s, e.e = t), n !== e.t && q(c, e.t = n), e;
				}, {
					e: void 0,
					t: void 0
				}), e;
			}
		})
	];
}
G(["input", "click"]);
//#endregion
//#region src/components/detail/DetailHeader.tsx
var wc = /*#__PURE__*/ W("<div class=detail-header><div><h2 style=margin:0;font-size:20px> <span>");
function Tc(e) {
	return (() => {
		var t = wc(), n = t.firstChild, r = n.firstChild, i = r.firstChild, a = i.nextSibling;
		return X(r, () => e.name, i), X(a, () => e.badgeLabel), X(n, () => e.subtitle, null), N(() => q(a, `badge ${e.badgeClass}`)), t;
	})();
}
//#endregion
//#region src/components/ui/BackButton.tsx
var Ec = /*#__PURE__*/ W("<button class=back-btn> Back to ");
function Dc(e) {
	return (() => {
		var t = Ec(), n = t.firstChild;
		return J(t, "click", e.onClick, !0), X(t, R(ui, { size: 14 }), n), X(t, () => e.label, null), t;
	})();
}
G(["click"]);
//#endregion
//#region src/components/detail/EntityListCard.tsx
var Oc = /*#__PURE__*/ W("<div class=entity-card-list>"), kc = /*#__PURE__*/ W("<div class=card><div class=card-header>"), Ac = /*#__PURE__*/ W("<h3>"), jc = /*#__PURE__*/ W("<span class=card-meta>"), Mc = /*#__PURE__*/ W("<p class=muted-note>");
function Nc(e) {
	let t = () => e.count == null ? e.title : `${e.title} (${e.count})`;
	return (() => {
		var n = kc(), r = n.firstChild;
		return X(r, (() => {
			var n = U(() => !!e.title);
			return () => n() && (() => {
				var e = Ac();
				return X(e, t), e;
			})();
		})(), null), X(r, (() => {
			var t = U(() => !!e.meta);
			return () => t() && (() => {
				var t = jc();
				return X(t, () => e.meta), t;
			})();
		})(), null), X(n, R(H, {
			get when() {
				return e.items.length > 0;
			},
			get fallback() {
				return (() => {
					var t = Mc();
					return X(t, () => e.emptyText ?? "None found."), t;
				})();
			},
			get children() {
				var t = Oc();
				return X(t, R(V, {
					get each() {
						return e.items;
					},
					children: (e) => R(mc, {
						get type() {
							return e.type;
						},
						get name() {
							return e.name;
						},
						get context() {
							return e.context;
						},
						get tooltip() {
							return e.tooltip;
						},
						get onClick() {
							return e.onClick;
						}
					})
				})), t;
			}
		}), null), n;
	})();
}
//#endregion
//#region src/features/objects/detail/MetricsGrid.tsx
var Pc = /*#__PURE__*/ W("<div class=metric-grid>"), Fc = /*#__PURE__*/ W("<div class=metric-card><div class=label></div><div class=value>");
function Ic(e) {
	return (() => {
		var t = Pc();
		return X(t, R(V, {
			get each() {
				return [
					["In Degree", e.metrics.in_degree],
					["Out Degree", e.metrics.out_degree],
					["Max CC", e.metrics.max_cyclomatic],
					["Avg CC", e.metrics.avg_cyclomatic ? parseFloat(String(e.metrics.avg_cyclomatic)).toFixed(1) : "–"],
					["PageRank", e.metrics.pagerank ? parseFloat(String(e.metrics.pagerank)).toFixed(4) : "–"],
					["DIT", e.metrics.dit ?? "–"]
				];
			},
			children: ([e, t]) => (() => {
				var n = Fc(), r = n.firstChild, i = r.nextSibling;
				return X(r, e), X(i, () => String(t ?? "–")), n;
			})()
		})), t;
	})();
}
//#endregion
//#region src/features/objects/detail/ProceduresCard.tsx
var Lc = /*#__PURE__*/ W("<div style=margin-bottom:12px><div style=\"font-size:11px;color:var(--text-muted);font-weight:600;margin-bottom:4px;padding:0 4px;text-transform:uppercase;letter-spacing:0.05em\"> (<!>)</div><table class=data-table><thead><tr><th>Name</th><th>Modifiers</th><th>Params</th><th>CC</th><th>Lines</th></tr></thead><tbody>"), Rc = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell></td><td style=font-size:12px></td><td style=font-size:12px;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap></td><td></td><td style=font-size:12px;color:var(--text-muted)>"), zc = /*#__PURE__*/ W("<span class=\"badge badge-cc\">"), Bc = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Procedures (<!>)"), Vc = [
	{
		label: "Functions",
		match: (e) => e === "function"
	},
	{
		label: "Events",
		match: (e) => e === "event"
	},
	{
		label: "Subroutines",
		match: (e) => e === "subroutine" || e === "on"
	}
];
function Hc(e) {
	return R(H, {
		get when() {
			return e.procs.length > 0;
		},
		get children() {
			var t = Lc(), n = t.firstChild, r = n.firstChild, i = r.nextSibling;
			i.nextSibling;
			var a = n.nextSibling.firstChild.nextSibling;
			return X(n, () => e.label, r), X(n, () => e.procs.length, i), X(a, R(V, {
				get each() {
					return e.procs;
				},
				children: (t) => (() => {
					var n = Rc(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.nextSibling, s = o.nextSibling;
					return n.$$click = () => e.store.dispatch({
						tag: "objects",
						action: {
							tag: "proc-select",
							objectName: e.objectName,
							procName: t.name
						}
					}), X(r, (() => {
						var n = U(() => !!(t.owner && t.owner !== e.objectName));
						return () => n() ? `${t.owner} · ${t.name}` : t.name;
					})()), X(i, () => t.modifiers ?? ""), X(a, () => t.params ?? ""), X(o, (() => {
						var e = U(() => t.cyclomatic != null);
						return () => e() ? (() => {
							var e = zc();
							return X(e, () => String(t.cyclomatic)), e;
						})() : "–";
					})()), X(s, (() => {
						var e = U(() => !!(t.start_line && t.end_line));
						return () => e() ? `${t.start_line}–${t.end_line}` : "–";
					})()), n;
				})()
			})), t;
		}
	});
}
function Uc(e) {
	return (() => {
		var t = Bc(), n = t.firstChild.firstChild, r = n.firstChild.nextSibling;
		return r.nextSibling, X(n, () => e.procedures.length, r), X(t, R(V, {
			each: Vc,
			children: (t) => R(Hc, {
				get label() {
					return t.label;
				},
				get procs() {
					return e.procedures.filter((e) => t.match(e.proc_type));
				},
				get objectName() {
					return e.objectName;
				},
				get store() {
					return e.store;
				}
			})
		}), null), t;
	})();
}
G(["click"]);
var Wc = (/* @__PURE__ */ c((/* @__PURE__ */ o(((e, t) => {
	function n(e) {
		return e instanceof Map ? e.clear = e.delete = e.set = function() {
			throw Error("map is read-only");
		} : e instanceof Set && (e.add = e.clear = e.delete = function() {
			throw Error("set is read-only");
		}), Object.freeze(e), Object.getOwnPropertyNames(e).forEach((t) => {
			let r = e[t], i = typeof r;
			(i === "object" || i === "function") && !Object.isFrozen(r) && n(r);
		}), e;
	}
	var r = class {
		constructor(e) {
			e.data === void 0 && (e.data = {}), this.data = e.data, this.isMatchIgnored = !1;
		}
		ignoreMatch() {
			this.isMatchIgnored = !0;
		}
	};
	function i(e) {
		return e.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;");
	}
	function a(e, ...t) {
		let n = Object.create(null);
		for (let t in e) n[t] = e[t];
		return t.forEach(function(e) {
			for (let t in e) n[t] = e[t];
		}), n;
	}
	var o = "</span>", s = (e) => !!e.scope, c = (e, { prefix: t }) => {
		if (e.startsWith("language:")) return e.replace("language:", "language-");
		if (e.includes(".")) {
			let n = e.split(".");
			return [`${t}${n.shift()}`, ...n.map((e, t) => `${e}${"_".repeat(t + 1)}`)].join(" ");
		}
		return `${t}${e}`;
	}, l = class {
		constructor(e, t) {
			this.buffer = "", this.classPrefix = t.classPrefix, e.walk(this);
		}
		addText(e) {
			this.buffer += i(e);
		}
		openNode(e) {
			if (!s(e)) return;
			let t = c(e.scope, { prefix: this.classPrefix });
			this.span(t);
		}
		closeNode(e) {
			s(e) && (this.buffer += o);
		}
		value() {
			return this.buffer;
		}
		span(e) {
			this.buffer += `<span class="${e}">`;
		}
	}, u = (e = {}) => {
		let t = { children: [] };
		return Object.assign(t, e), t;
	}, d = class e {
		constructor() {
			this.rootNode = u(), this.stack = [this.rootNode];
		}
		get top() {
			return this.stack[this.stack.length - 1];
		}
		get root() {
			return this.rootNode;
		}
		add(e) {
			this.top.children.push(e);
		}
		openNode(e) {
			let t = u({ scope: e });
			this.add(t), this.stack.push(t);
		}
		closeNode() {
			if (this.stack.length > 1) return this.stack.pop();
		}
		closeAllNodes() {
			for (; this.closeNode(););
		}
		toJSON() {
			return JSON.stringify(this.rootNode, null, 4);
		}
		walk(e) {
			return this.constructor._walk(e, this.rootNode);
		}
		static _walk(e, t) {
			return typeof t == "string" ? e.addText(t) : t.children && (e.openNode(t), t.children.forEach((t) => this._walk(e, t)), e.closeNode(t)), e;
		}
		static _collapse(t) {
			typeof t != "string" && t.children && (t.children.every((e) => typeof e == "string") ? t.children = [t.children.join("")] : t.children.forEach((t) => {
				e._collapse(t);
			}));
		}
	}, f = class extends d {
		constructor(e) {
			super(), this.options = e;
		}
		addText(e) {
			e !== "" && this.add(e);
		}
		startScope(e) {
			this.openNode(e);
		}
		endScope() {
			this.closeNode();
		}
		__addSublanguage(e, t) {
			let n = e.root;
			t && (n.scope = `language:${t}`), this.add(n);
		}
		toHTML() {
			return new l(this, this.options).value();
		}
		finalize() {
			return this.closeAllNodes(), !0;
		}
	};
	function p(e) {
		return e ? typeof e == "string" ? e : e.source : null;
	}
	function m(e) {
		return _("(?=", e, ")");
	}
	function h(e) {
		return _("(?:", e, ")*");
	}
	function g(e) {
		return _("(?:", e, ")?");
	}
	function _(...e) {
		return e.map((e) => p(e)).join("");
	}
	function v(e) {
		let t = e[e.length - 1];
		return typeof t == "object" && t.constructor === Object ? (e.splice(e.length - 1, 1), t) : {};
	}
	function y(...e) {
		return "(" + (v(e).capture ? "" : "?:") + e.map((e) => p(e)).join("|") + ")";
	}
	function b(e) {
		return RegExp(e.toString() + "|").exec("").length - 1;
	}
	function x(e, t) {
		let n = e && e.exec(t);
		return n && n.index === 0;
	}
	var ee = /\[(?:[^\\\]]|\\.)*\]|\(\??|\\([1-9][0-9]*)|\\./;
	function S(e, { joinWith: t }) {
		let n = 0;
		return e.map((e) => {
			n += 1;
			let t = n, r = p(e), i = "";
			for (; r.length > 0;) {
				let e = ee.exec(r);
				if (!e) {
					i += r;
					break;
				}
				i += r.substring(0, e.index), r = r.substring(e.index + e[0].length), e[0][0] === "\\" && e[1] ? i += "\\" + String(Number(e[1]) + t) : (i += e[0], e[0] === "(" && n++);
			}
			return i;
		}).map((e) => `(${e})`).join(t);
	}
	var C = /\b\B/, w = "[a-zA-Z]\\w*", T = "[a-zA-Z_]\\w*", E = "\\b\\d+(\\.\\d+)?", D = "(-?)(\\b0[xX][a-fA-F0-9]+|(\\b\\d+(\\.\\d*)?|\\.\\d+)([eE][-+]?\\d+)?)", O = "\\b(0b[01]+)", k = "!|!=|!==|%|%=|&|&&|&=|\\*|\\*=|\\+|\\+=|,|-|-=|/=|/|:|;|<<|<<=|<=|<|===|==|=|>>>=|>>=|>=|>>>|>>|>|\\?|\\[|\\{|\\(|\\^|\\^=|\\||\\|=|\\|\\||~", te = (e = {}) => {
		let t = /^#![ ]*\//;
		return e.binary && (e.begin = _(t, /.*\b/, e.binary, /\b.*/)), a({
			scope: "meta",
			begin: t,
			end: /$/,
			relevance: 0,
			"on:begin": (e, t) => {
				e.index !== 0 && t.ignoreMatch();
			}
		}, e);
	}, A = {
		begin: "\\\\[\\s\\S]",
		relevance: 0
	}, j = {
		scope: "string",
		begin: "'",
		end: "'",
		illegal: "\\n",
		contains: [A]
	}, M = {
		scope: "string",
		begin: "\"",
		end: "\"",
		illegal: "\\n",
		contains: [A]
	}, N = { begin: /\b(a|an|the|are|I'm|isn't|don't|doesn't|won't|but|just|should|pretty|simply|enough|gonna|going|wtf|so|such|will|you|your|they|like|more)\b/ }, P = function(e, t, n = {}) {
		let r = a({
			scope: "comment",
			begin: e,
			end: t,
			contains: []
		}, n);
		r.contains.push({
			scope: "doctag",
			begin: "[ ]*(?=(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):)",
			end: /(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):/,
			excludeBegin: !0,
			relevance: 0
		});
		let i = y("I", "a", "is", "so", "us", "to", "at", "if", "in", "it", "on", /[A-Za-z]+['](d|ve|re|ll|t|s|n)/, /[A-Za-z]+[-][a-z]+/, /[A-Za-z][a-z]{2,}/);
		return r.contains.push({ begin: _(/[ ]+/, "(", i, /[.]?[:]?([.][ ]|[ ])/, "){3}") }), r;
	}, F = P("//", "$"), ne = P("/\\*", "\\*/"), re = P("#", "$"), I = /*#__PURE__*/ Object.freeze({
		__proto__: null,
		APOS_STRING_MODE: j,
		BACKSLASH_ESCAPE: A,
		BINARY_NUMBER_MODE: {
			scope: "number",
			begin: O,
			relevance: 0
		},
		BINARY_NUMBER_RE: O,
		COMMENT: P,
		C_BLOCK_COMMENT_MODE: ne,
		C_LINE_COMMENT_MODE: F,
		C_NUMBER_MODE: {
			scope: "number",
			begin: D,
			relevance: 0
		},
		C_NUMBER_RE: D,
		END_SAME_AS_BEGIN: function(e) {
			return Object.assign(e, {
				"on:begin": (e, t) => {
					t.data._beginMatch = e[1];
				},
				"on:end": (e, t) => {
					t.data._beginMatch !== e[1] && t.ignoreMatch();
				}
			});
		},
		HASH_COMMENT_MODE: re,
		IDENT_RE: w,
		MATCH_NOTHING_RE: C,
		METHOD_GUARD: {
			begin: "\\.\\s*[a-zA-Z_]\\w*",
			relevance: 0
		},
		NUMBER_MODE: {
			scope: "number",
			begin: E,
			relevance: 0
		},
		NUMBER_RE: E,
		PHRASAL_WORDS_MODE: N,
		QUOTE_STRING_MODE: M,
		REGEXP_MODE: {
			scope: "regexp",
			begin: /\/(?=[^/\n]*\/)/,
			end: /\/[gimuy]*/,
			contains: [A, {
				begin: /\[/,
				end: /\]/,
				relevance: 0,
				contains: [A]
			}]
		},
		RE_STARTERS_RE: k,
		SHEBANG: te,
		TITLE_MODE: {
			scope: "title",
			begin: w,
			relevance: 0
		},
		UNDERSCORE_IDENT_RE: T,
		UNDERSCORE_TITLE_MODE: {
			scope: "title",
			begin: T,
			relevance: 0
		}
	});
	function ie(e, t) {
		e.input[e.index - 1] === "." && t.ignoreMatch();
	}
	function ae(e, t) {
		e.className !== void 0 && (e.scope = e.className, delete e.className);
	}
	function L(e, t) {
		t && e.beginKeywords && (e.begin = "\\b(" + e.beginKeywords.split(" ").join("|") + ")(?!\\.)(?=\\b|\\s)", e.__beforeBegin = ie, e.keywords = e.keywords || e.beginKeywords, delete e.beginKeywords, e.relevance === void 0 && (e.relevance = 0));
	}
	function oe(e, t) {
		Array.isArray(e.illegal) && (e.illegal = y(...e.illegal));
	}
	function se(e, t) {
		if (e.match) {
			if (e.begin || e.end) throw Error("begin & end are not supported with match");
			e.begin = e.match, delete e.match;
		}
	}
	function ce(e, t) {
		e.relevance === void 0 && (e.relevance = 1);
	}
	var le = (e, t) => {
		if (!e.beforeMatch) return;
		if (e.starts) throw Error("beforeMatch cannot be used with starts");
		let n = Object.assign({}, e);
		Object.keys(e).forEach((t) => {
			delete e[t];
		}), e.keywords = n.keywords, e.begin = _(n.beforeMatch, m(n.begin)), e.starts = {
			relevance: 0,
			contains: [Object.assign(n, { endsParent: !0 })]
		}, e.relevance = 0, delete n.beforeMatch;
	}, ue = [
		"of",
		"and",
		"for",
		"in",
		"not",
		"or",
		"if",
		"then",
		"parent",
		"list",
		"value"
	], de = "keyword";
	function fe(e, t, n = de) {
		let r = Object.create(null);
		return typeof e == "string" ? i(n, e.split(" ")) : Array.isArray(e) ? i(n, e) : Object.keys(e).forEach(function(n) {
			Object.assign(r, fe(e[n], t, n));
		}), r;
		function i(e, n) {
			t && (n = n.map((e) => e.toLowerCase())), n.forEach(function(t) {
				let n = t.split("|");
				r[n[0]] = [e, pe(n[0], n[1])];
			});
		}
	}
	function pe(e, t) {
		return t ? Number(t) : +!me(e);
	}
	function me(e) {
		return ue.includes(e.toLowerCase());
	}
	var he = {}, ge = (e) => {
		console.error(e);
	}, _e = (e, ...t) => {
		console.log(`WARN: ${e}`, ...t);
	}, ve = (e, t) => {
		he[`${e}/${t}`] || (console.log(`Deprecated as of ${e}. ${t}`), he[`${e}/${t}`] = !0);
	}, ye = /* @__PURE__ */ Error();
	function be(e, t, { key: n }) {
		let r = 0, i = e[n], a = {}, o = {};
		for (let e = 1; e <= t.length; e++) o[e + r] = i[e], a[e + r] = !0, r += b(t[e - 1]);
		e[n] = o, e[n]._emit = a, e[n]._multi = !0;
	}
	function xe(e) {
		if (Array.isArray(e.begin)) {
			if (e.skip || e.excludeBegin || e.returnBegin) throw ge("skip, excludeBegin, returnBegin not compatible with beginScope: {}"), ye;
			if (typeof e.beginScope != "object" || e.beginScope === null) throw ge("beginScope must be object"), ye;
			be(e, e.begin, { key: "beginScope" }), e.begin = S(e.begin, { joinWith: "" });
		}
	}
	function Se(e) {
		if (Array.isArray(e.end)) {
			if (e.skip || e.excludeEnd || e.returnEnd) throw ge("skip, excludeEnd, returnEnd not compatible with endScope: {}"), ye;
			if (typeof e.endScope != "object" || e.endScope === null) throw ge("endScope must be object"), ye;
			be(e, e.end, { key: "endScope" }), e.end = S(e.end, { joinWith: "" });
		}
	}
	function Ce(e) {
		e.scope && typeof e.scope == "object" && e.scope !== null && (e.beginScope = e.scope, delete e.scope);
	}
	function we(e) {
		Ce(e), typeof e.beginScope == "string" && (e.beginScope = { _wrap: e.beginScope }), typeof e.endScope == "string" && (e.endScope = { _wrap: e.endScope }), xe(e), Se(e);
	}
	function Te(e) {
		function t(t, n) {
			return new RegExp(p(t), "m" + (e.case_insensitive ? "i" : "") + (e.unicodeRegex ? "u" : "") + (n ? "g" : ""));
		}
		class n {
			constructor() {
				this.matchIndexes = {}, this.regexes = [], this.matchAt = 1, this.position = 0;
			}
			addRule(e, t) {
				t.position = this.position++, this.matchIndexes[this.matchAt] = t, this.regexes.push([t, e]), this.matchAt += b(e) + 1;
			}
			compile() {
				this.regexes.length === 0 && (this.exec = () => null);
				let e = this.regexes.map((e) => e[1]);
				this.matcherRe = t(S(e, { joinWith: "|" }), !0), this.lastIndex = 0;
			}
			exec(e) {
				this.matcherRe.lastIndex = this.lastIndex;
				let t = this.matcherRe.exec(e);
				if (!t) return null;
				let n = t.findIndex((e, t) => t > 0 && e !== void 0), r = this.matchIndexes[n];
				return t.splice(0, n), Object.assign(t, r);
			}
		}
		class r {
			constructor() {
				this.rules = [], this.multiRegexes = [], this.count = 0, this.lastIndex = 0, this.regexIndex = 0;
			}
			getMatcher(e) {
				if (this.multiRegexes[e]) return this.multiRegexes[e];
				let t = new n();
				return this.rules.slice(e).forEach(([e, n]) => t.addRule(e, n)), t.compile(), this.multiRegexes[e] = t, t;
			}
			resumingScanAtSamePosition() {
				return this.regexIndex !== 0;
			}
			considerAll() {
				this.regexIndex = 0;
			}
			addRule(e, t) {
				this.rules.push([e, t]), t.type === "begin" && this.count++;
			}
			exec(e) {
				let t = this.getMatcher(this.regexIndex);
				t.lastIndex = this.lastIndex;
				let n = t.exec(e);
				if (this.resumingScanAtSamePosition() && !(n && n.index === this.lastIndex)) {
					let t = this.getMatcher(0);
					t.lastIndex = this.lastIndex + 1, n = t.exec(e);
				}
				return n && (this.regexIndex += n.position + 1, this.regexIndex === this.count && this.considerAll()), n;
			}
		}
		function i(e) {
			let t = new r();
			return e.contains.forEach((e) => t.addRule(e.begin, {
				rule: e,
				type: "begin"
			})), e.terminatorEnd && t.addRule(e.terminatorEnd, { type: "end" }), e.illegal && t.addRule(e.illegal, { type: "illegal" }), t;
		}
		function o(n, r) {
			let a = n;
			if (n.isCompiled) return a;
			[
				ae,
				se,
				we,
				le
			].forEach((e) => e(n, r)), e.compilerExtensions.forEach((e) => e(n, r)), n.__beforeBegin = null, [
				L,
				oe,
				ce
			].forEach((e) => e(n, r)), n.isCompiled = !0;
			let s = null;
			return typeof n.keywords == "object" && n.keywords.$pattern && (n.keywords = Object.assign({}, n.keywords), s = n.keywords.$pattern, delete n.keywords.$pattern), s ||= /\w+/, n.keywords &&= fe(n.keywords, e.case_insensitive), a.keywordPatternRe = t(s, !0), r && (n.begin ||= /\B|\b/, a.beginRe = t(a.begin), !n.end && !n.endsWithParent && (n.end = /\B|\b/), n.end && (a.endRe = t(a.end)), a.terminatorEnd = p(a.end) || "", n.endsWithParent && r.terminatorEnd && (a.terminatorEnd += (n.end ? "|" : "") + r.terminatorEnd)), n.illegal && (a.illegalRe = t(n.illegal)), n.contains ||= [], n.contains = [].concat(...n.contains.map(function(e) {
				return De(e === "self" ? n : e);
			})), n.contains.forEach(function(e) {
				o(e, a);
			}), n.starts && o(n.starts, r), a.matcher = i(a), a;
		}
		if (e.compilerExtensions ||= [], e.contains && e.contains.includes("self")) throw Error("ERR: contains `self` is not supported at the top-level of a language.  See documentation.");
		return e.classNameAliases = a(e.classNameAliases || {}), o(e);
	}
	function Ee(e) {
		return e ? e.endsWithParent || Ee(e.starts) : !1;
	}
	function De(e) {
		return e.variants && !e.cachedVariants && (e.cachedVariants = e.variants.map(function(t) {
			return a(e, { variants: null }, t);
		})), e.cachedVariants ? e.cachedVariants : Ee(e) ? a(e, { starts: e.starts ? a(e.starts) : null }) : Object.isFrozen(e) ? a(e) : e;
	}
	var Oe = "11.11.1", ke = class extends Error {
		constructor(e, t) {
			super(e), this.name = "HTMLInjectionError", this.html = t;
		}
	}, Ae = i, je = a, Me = Symbol("nomatch"), Ne = 7, Pe = function(e) {
		let t = Object.create(null), i = Object.create(null), a = [], o = !0, s = "Could not find the language '{}', did you forget to load/include a language module?", c = {
			disableAutodetect: !0,
			name: "Plain text",
			contains: []
		}, l = {
			ignoreUnescapedHTML: !1,
			throwUnescapedHTML: !1,
			noHighlightRe: /^(no-?highlight)$/i,
			languageDetectRe: /\blang(?:uage)?-([\w-]+)\b/i,
			classPrefix: "hljs-",
			cssSelector: "pre code",
			languages: null,
			__emitter: f
		};
		function u(e) {
			return l.noHighlightRe.test(e);
		}
		function d(e) {
			let t = e.className + " ";
			t += e.parentNode ? e.parentNode.className : "";
			let n = l.languageDetectRe.exec(t);
			if (n) {
				let t = j(n[1]);
				return t || (_e(s.replace("{}", n[1])), _e("Falling back to no-highlight mode for this block.", e)), t ? n[1] : "no-highlight";
			}
			return t.split(/\s+/).find((e) => u(e) || j(e));
		}
		function p(e, t, n) {
			let r = "", i = "";
			typeof t == "object" ? (r = e, n = t.ignoreIllegals, i = t.language) : (ve("10.7.0", "highlight(lang, code, ...args) has been deprecated."), ve("10.7.0", "Please use highlight(code, options) instead.\nhttps://github.com/highlightjs/highlight.js/issues/2277"), i = e, r = t), n === void 0 && (n = !0);
			let a = {
				code: r,
				language: i
			};
			re("before:highlight", a);
			let o = a.result ? a.result : v(a.language, a.code, n);
			return o.code = a.code, re("after:highlight", o), o;
		}
		function v(e, n, i, a) {
			let c = Object.create(null);
			function u(e, t) {
				return e.keywords[t];
			}
			function d() {
				if (!k.keywords) {
					A.addText(M);
					return;
				}
				let e = 0;
				k.keywordPatternRe.lastIndex = 0;
				let t = k.keywordPatternRe.exec(M), n = "";
				for (; t;) {
					n += M.substring(e, t.index);
					let r = E.case_insensitive ? t[0].toLowerCase() : t[0], i = u(k, r);
					if (i) {
						let [e, a] = i;
						if (A.addText(n), n = "", c[r] = (c[r] || 0) + 1, c[r] <= Ne && (N += a), e.startsWith("_")) n += t[0];
						else {
							let n = E.classNameAliases[e] || e;
							m(t[0], n);
						}
					} else n += t[0];
					e = k.keywordPatternRe.lastIndex, t = k.keywordPatternRe.exec(M);
				}
				n += M.substring(e), A.addText(n);
			}
			function f() {
				if (M === "") return;
				let e = null;
				if (typeof k.subLanguage == "string") {
					if (!t[k.subLanguage]) {
						A.addText(M);
						return;
					}
					e = v(k.subLanguage, M, !0, te[k.subLanguage]), te[k.subLanguage] = e._top;
				} else e = ee(M, k.subLanguage.length ? k.subLanguage : null);
				k.relevance > 0 && (N += e.relevance), A.__addSublanguage(e._emitter, e.language);
			}
			function p() {
				k.subLanguage == null ? d() : f(), M = "";
			}
			function m(e, t) {
				e !== "" && (A.startScope(t), A.addText(e), A.endScope());
			}
			function h(e, t) {
				let n = 1, r = t.length - 1;
				for (; n <= r;) {
					if (!e._emit[n]) {
						n++;
						continue;
					}
					let r = E.classNameAliases[e[n]] || e[n], i = t[n];
					r ? m(i, r) : (M = i, d(), M = ""), n++;
				}
			}
			function g(e, t) {
				return e.scope && typeof e.scope == "string" && A.openNode(E.classNameAliases[e.scope] || e.scope), e.beginScope && (e.beginScope._wrap ? (m(M, E.classNameAliases[e.beginScope._wrap] || e.beginScope._wrap), M = "") : e.beginScope._multi && (h(e.beginScope, t), M = "")), k = Object.create(e, { parent: { value: k } }), k;
			}
			function _(e, t, n) {
				let i = x(e.endRe, n);
				if (i) {
					if (e["on:end"]) {
						let n = new r(e);
						e["on:end"](t, n), n.isMatchIgnored && (i = !1);
					}
					if (i) {
						for (; e.endsParent && e.parent;) e = e.parent;
						return e;
					}
				}
				if (e.endsWithParent) return _(e.parent, t, n);
			}
			function y(e) {
				return k.matcher.regexIndex === 0 ? (M += e[0], 1) : (ne = !0, 0);
			}
			function b(e) {
				let t = e[0], n = e.rule, i = new r(n), a = [n.__beforeBegin, n["on:begin"]];
				for (let n of a) if (n && (n(e, i), i.isMatchIgnored)) return y(t);
				return n.skip ? M += t : (n.excludeBegin && (M += t), p(), !n.returnBegin && !n.excludeBegin && (M = t)), g(n, e), n.returnBegin ? 0 : t.length;
			}
			function S(e) {
				let t = e[0], r = n.substring(e.index), i = _(k, e, r);
				if (!i) return Me;
				let a = k;
				k.endScope && k.endScope._wrap ? (p(), m(t, k.endScope._wrap)) : k.endScope && k.endScope._multi ? (p(), h(k.endScope, e)) : a.skip ? M += t : (a.returnEnd || a.excludeEnd || (M += t), p(), a.excludeEnd && (M = t));
				do
					k.scope && A.closeNode(), !k.skip && !k.subLanguage && (N += k.relevance), k = k.parent;
				while (k !== i.parent);
				return i.starts && g(i.starts, e), a.returnEnd ? 0 : t.length;
			}
			function C() {
				let e = [];
				for (let t = k; t !== E; t = t.parent) t.scope && e.unshift(t.scope);
				e.forEach((e) => A.openNode(e));
			}
			let w = {};
			function T(t, r) {
				let a = r && r[0];
				if (M += t, a == null) return p(), 0;
				if (w.type === "begin" && r.type === "end" && w.index === r.index && a === "") {
					if (M += n.slice(r.index, r.index + 1), !o) {
						let t = /* @__PURE__ */ Error(`0 width match regex (${e})`);
						throw t.languageName = e, t.badRule = w.rule, t;
					}
					return 1;
				}
				if (w = r, r.type === "begin") return b(r);
				if (r.type === "illegal" && !i) {
					let e = /* @__PURE__ */ Error("Illegal lexeme \"" + a + "\" for mode \"" + (k.scope || "<unnamed>") + "\"");
					throw e.mode = k, e;
				} else if (r.type === "end") {
					let e = S(r);
					if (e !== Me) return e;
				}
				if (r.type === "illegal" && a === "") return M += "\n", 1;
				if (F > 1e5 && F > r.index * 3) throw /* @__PURE__ */ Error("potential infinite loop, way more iterations than matches");
				return M += a, a.length;
			}
			let E = j(e);
			if (!E) throw ge(s.replace("{}", e)), Error("Unknown language: \"" + e + "\"");
			let D = Te(E), O = "", k = a || D, te = {}, A = new l.__emitter(l);
			C();
			let M = "", N = 0, P = 0, F = 0, ne = !1;
			try {
				if (E.__emitTokens) E.__emitTokens(n, A);
				else {
					for (k.matcher.considerAll();;) {
						F++, ne ? ne = !1 : k.matcher.considerAll(), k.matcher.lastIndex = P;
						let e = k.matcher.exec(n);
						if (!e) break;
						let t = T(n.substring(P, e.index), e);
						P = e.index + t;
					}
					T(n.substring(P));
				}
				return A.finalize(), O = A.toHTML(), {
					language: e,
					value: O,
					relevance: N,
					illegal: !1,
					_emitter: A,
					_top: k
				};
			} catch (t) {
				if (t.message && t.message.includes("Illegal")) return {
					language: e,
					value: Ae(n),
					illegal: !0,
					relevance: 0,
					_illegalBy: {
						message: t.message,
						index: P,
						context: n.slice(P - 100, P + 100),
						mode: t.mode,
						resultSoFar: O
					},
					_emitter: A
				};
				if (o) return {
					language: e,
					value: Ae(n),
					illegal: !1,
					relevance: 0,
					errorRaised: t,
					_emitter: A,
					_top: k
				};
				throw t;
			}
		}
		function b(e) {
			let t = {
				value: Ae(e),
				illegal: !1,
				relevance: 0,
				_top: c,
				_emitter: new l.__emitter(l)
			};
			return t._emitter.addText(e), t;
		}
		function ee(e, n) {
			n = n || l.languages || Object.keys(t);
			let r = b(e), i = n.filter(j).filter(N).map((t) => v(t, e, !1));
			i.unshift(r);
			let [a, o] = i.sort((e, t) => {
				if (e.relevance !== t.relevance) return t.relevance - e.relevance;
				if (e.language && t.language) {
					if (j(e.language).supersetOf === t.language) return 1;
					if (j(t.language).supersetOf === e.language) return -1;
				}
				return 0;
			}), s = a;
			return s.secondBest = o, s;
		}
		function S(e, t, n) {
			let r = t && i[t] || n;
			e.classList.add("hljs"), e.classList.add(`language-${r}`);
		}
		function C(e) {
			let t = null, n = d(e);
			if (u(n)) return;
			if (re("before:highlightElement", {
				el: e,
				language: n
			}), e.dataset.highlighted) {
				console.log("Element previously highlighted. To highlight again, first unset `dataset.highlighted`.", e);
				return;
			}
			if (e.children.length > 0 && (l.ignoreUnescapedHTML || (console.warn("One of your code blocks includes unescaped HTML. This is a potentially serious security risk."), console.warn("https://github.com/highlightjs/highlight.js/wiki/security"), console.warn("The element with unescaped HTML:"), console.warn(e)), l.throwUnescapedHTML)) throw new ke("One of your code blocks includes unescaped HTML.", e.innerHTML);
			t = e;
			let r = t.textContent, i = n ? p(r, {
				language: n,
				ignoreIllegals: !0
			}) : ee(r);
			e.innerHTML = i.value, e.dataset.highlighted = "yes", S(e, n, i.language), e.result = {
				language: i.language,
				re: i.relevance,
				relevance: i.relevance
			}, i.secondBest && (e.secondBest = {
				language: i.secondBest.language,
				relevance: i.secondBest.relevance
			}), re("after:highlightElement", {
				el: e,
				result: i,
				text: r
			});
		}
		function w(e) {
			l = je(l, e);
		}
		let T = () => {
			O(), ve("10.6.0", "initHighlighting() deprecated.  Use highlightAll() now.");
		};
		function E() {
			O(), ve("10.6.0", "initHighlightingOnLoad() deprecated.  Use highlightAll() now.");
		}
		let D = !1;
		function O() {
			function e() {
				O();
			}
			if (document.readyState === "loading") {
				D || window.addEventListener("DOMContentLoaded", e, !1), D = !0;
				return;
			}
			document.querySelectorAll(l.cssSelector).forEach(C);
		}
		function k(n, r) {
			let i = null;
			try {
				i = r(e);
			} catch (e) {
				if (ge("Language definition for '{}' could not be registered.".replace("{}", n)), o) ge(e);
				else throw e;
				i = c;
			}
			i.name ||= n, t[n] = i, i.rawDefinition = r.bind(null, e), i.aliases && M(i.aliases, { languageName: n });
		}
		function te(e) {
			delete t[e];
			for (let t of Object.keys(i)) i[t] === e && delete i[t];
		}
		function A() {
			return Object.keys(t);
		}
		function j(e) {
			return e = (e || "").toLowerCase(), t[e] || t[i[e]];
		}
		function M(e, { languageName: t }) {
			typeof e == "string" && (e = [e]), e.forEach((e) => {
				i[e.toLowerCase()] = t;
			});
		}
		function N(e) {
			let t = j(e);
			return t && !t.disableAutodetect;
		}
		function P(e) {
			e["before:highlightBlock"] && !e["before:highlightElement"] && (e["before:highlightElement"] = (t) => {
				e["before:highlightBlock"](Object.assign({ block: t.el }, t));
			}), e["after:highlightBlock"] && !e["after:highlightElement"] && (e["after:highlightElement"] = (t) => {
				e["after:highlightBlock"](Object.assign({ block: t.el }, t));
			});
		}
		function F(e) {
			P(e), a.push(e);
		}
		function ne(e) {
			let t = a.indexOf(e);
			t !== -1 && a.splice(t, 1);
		}
		function re(e, t) {
			let n = e;
			a.forEach(function(e) {
				e[n] && e[n](t);
			});
		}
		function ie(e) {
			return ve("10.7.0", "highlightBlock will be removed entirely in v12.0"), ve("10.7.0", "Please use highlightElement now."), C(e);
		}
		Object.assign(e, {
			highlight: p,
			highlightAuto: ee,
			highlightAll: O,
			highlightElement: C,
			highlightBlock: ie,
			configure: w,
			initHighlighting: T,
			initHighlightingOnLoad: E,
			registerLanguage: k,
			unregisterLanguage: te,
			listLanguages: A,
			getLanguage: j,
			registerAliases: M,
			autoDetection: N,
			inherit: je,
			addPlugin: F,
			removePlugin: ne
		}), e.debugMode = function() {
			o = !1;
		}, e.safeMode = function() {
			o = !0;
		}, e.versionString = Oe, e.regex = {
			concat: _,
			lookahead: m,
			either: y,
			optional: g,
			anyNumberOfTimes: h
		};
		for (let e in I) typeof I[e] == "object" && n(I[e]);
		return Object.assign(e, I), e;
	}, Fe = Pe({});
	Fe.newInstance = () => Pe({}), t.exports = Fe, Fe.HighlightJS = Fe, Fe.default = Fe;
})))())).default;
//#endregion
//#region node_modules/.pnpm/highlight.js@11.11.1/node_modules/highlight.js/es/languages/sql.js
function Gc(e) {
	let t = e.regex, n = e.COMMENT("--", "$"), r = {
		scope: "string",
		variants: [{
			begin: /'/,
			end: /'/,
			contains: [{ match: /''/ }]
		}]
	}, i = {
		begin: /"/,
		end: /"/,
		contains: [{ match: /""/ }]
	}, a = [
		"true",
		"false",
		"unknown"
	], o = [
		"double precision",
		"large object",
		"with timezone",
		"without timezone"
	], s = /* @__PURE__ */ "bigint.binary.blob.boolean.char.character.clob.date.dec.decfloat.decimal.float.int.integer.interval.nchar.nclob.national.numeric.real.row.smallint.time.timestamp.varchar.varying.varbinary".split("."), c = [
		"add",
		"asc",
		"collation",
		"desc",
		"final",
		"first",
		"last",
		"view"
	], l = /* @__PURE__ */ "abs.acos.all.allocate.alter.and.any.are.array.array_agg.array_max_cardinality.as.asensitive.asin.asymmetric.at.atan.atomic.authorization.avg.begin.begin_frame.begin_partition.between.bigint.binary.blob.boolean.both.by.call.called.cardinality.cascaded.case.cast.ceil.ceiling.char.char_length.character.character_length.check.classifier.clob.close.coalesce.collate.collect.column.commit.condition.connect.constraint.contains.convert.copy.corr.corresponding.cos.cosh.count.covar_pop.covar_samp.create.cross.cube.cume_dist.current.current_catalog.current_date.current_default_transform_group.current_path.current_role.current_row.current_schema.current_time.current_timestamp.current_path.current_role.current_transform_group_for_type.current_user.cursor.cycle.date.day.deallocate.dec.decimal.decfloat.declare.default.define.delete.dense_rank.deref.describe.deterministic.disconnect.distinct.double.drop.dynamic.each.element.else.empty.end.end_frame.end_partition.end-exec.equals.escape.every.except.exec.execute.exists.exp.external.extract.false.fetch.filter.first_value.float.floor.for.foreign.frame_row.free.from.full.function.fusion.get.global.grant.group.grouping.groups.having.hold.hour.identity.in.indicator.initial.inner.inout.insensitive.insert.int.integer.intersect.intersection.interval.into.is.join.json_array.json_arrayagg.json_exists.json_object.json_objectagg.json_query.json_table.json_table_primitive.json_value.lag.language.large.last_value.lateral.lead.leading.left.like.like_regex.listagg.ln.local.localtime.localtimestamp.log.log10.lower.match.match_number.match_recognize.matches.max.member.merge.method.min.minute.mod.modifies.module.month.multiset.national.natural.nchar.nclob.new.no.none.normalize.not.nth_value.ntile.null.nullif.numeric.octet_length.occurrences_regex.of.offset.old.omit.on.one.only.open.or.order.out.outer.over.overlaps.overlay.parameter.partition.pattern.per.percent.percent_rank.percentile_cont.percentile_disc.period.portion.position.position_regex.power.precedes.precision.prepare.primary.procedure.ptf.range.rank.reads.real.recursive.ref.references.referencing.regr_avgx.regr_avgy.regr_count.regr_intercept.regr_r2.regr_slope.regr_sxx.regr_sxy.regr_syy.release.result.return.returns.revoke.right.rollback.rollup.row.row_number.rows.running.savepoint.scope.scroll.search.second.seek.select.sensitive.session_user.set.show.similar.sin.sinh.skip.smallint.some.specific.specifictype.sql.sqlexception.sqlstate.sqlwarning.sqrt.start.static.stddev_pop.stddev_samp.submultiset.subset.substring.substring_regex.succeeds.sum.symmetric.system.system_time.system_user.table.tablesample.tan.tanh.then.time.timestamp.timezone_hour.timezone_minute.to.trailing.translate.translate_regex.translation.treat.trigger.trim.trim_array.true.truncate.uescape.union.unique.unknown.unnest.update.upper.user.using.value.values.value_of.var_pop.var_samp.varbinary.varchar.varying.versioning.when.whenever.where.width_bucket.window.with.within.without.year".split("."), u = /* @__PURE__ */ "abs.acos.array_agg.asin.atan.avg.cast.ceil.ceiling.coalesce.corr.cos.cosh.count.covar_pop.covar_samp.cume_dist.dense_rank.deref.element.exp.extract.first_value.floor.json_array.json_arrayagg.json_exists.json_object.json_objectagg.json_query.json_table.json_table_primitive.json_value.lag.last_value.lead.listagg.ln.log.log10.lower.max.min.mod.nth_value.ntile.nullif.percent_rank.percentile_cont.percentile_disc.position.position_regex.power.rank.regr_avgx.regr_avgy.regr_count.regr_intercept.regr_r2.regr_slope.regr_sxx.regr_sxy.regr_syy.row_number.sin.sinh.sqrt.stddev_pop.stddev_samp.substring.substring_regex.sum.tan.tanh.translate.translate_regex.treat.trim.trim_array.unnest.upper.value_of.var_pop.var_samp.width_bucket".split("."), d = [
		"current_catalog",
		"current_date",
		"current_default_transform_group",
		"current_path",
		"current_role",
		"current_schema",
		"current_transform_group_for_type",
		"current_user",
		"session_user",
		"system_time",
		"system_user",
		"current_time",
		"localtime",
		"current_timestamp",
		"localtimestamp"
	], f = [
		"create table",
		"insert into",
		"primary key",
		"foreign key",
		"not null",
		"alter table",
		"add constraint",
		"grouping sets",
		"on overflow",
		"character set",
		"respect nulls",
		"ignore nulls",
		"nulls first",
		"nulls last",
		"depth first",
		"breadth first"
	], p = u, m = [...l, ...c].filter((e) => !u.includes(e)), h = {
		scope: "variable",
		match: /@[a-z0-9][a-z0-9_]*/
	}, g = {
		scope: "operator",
		match: /[-+*/=%^~]|&&?|\|\|?|!=?|<(?:=>?|<|>)?|>[>=]?/,
		relevance: 0
	}, _ = {
		match: t.concat(/\b/, t.either(...p), /\s*\(/),
		relevance: 0,
		keywords: { built_in: p }
	};
	function v(e) {
		return t.concat(/\b/, t.either(...e.map((e) => e.replace(/\s+/, "\\s+"))), /\b/);
	}
	let y = {
		scope: "keyword",
		match: v(f),
		relevance: 0
	};
	function b(e, { exceptions: t, when: n } = {}) {
		let r = n;
		return t ||= [], e.map((e) => e.match(/\|\d+$/) || t.includes(e) ? e : r(e) ? `${e}|0` : e);
	}
	return {
		name: "SQL",
		case_insensitive: !0,
		illegal: /[{}]|<\//,
		keywords: {
			$pattern: /\b[\w\.]+/,
			keyword: b(m, { when: (e) => e.length < 3 }),
			literal: a,
			type: s,
			built_in: d
		},
		contains: [
			{
				scope: "type",
				match: v(o)
			},
			y,
			_,
			h,
			r,
			i,
			e.C_NUMBER_MODE,
			e.C_BLOCK_COMMENT_MODE,
			n,
			g
		]
	};
}
//#endregion
//#region src/utils/highlight.ts
var Kc = new Set(/* @__PURE__ */ "and.or.not.xor.if.then.else.elseif.end.choose.case.for.to.step.next.do.while.loop.until.exit.continue.try.catch.finally.throw.throws.return.halt.goto.call.post.trigger.dynamic.with.close.open.create.destroy.using.set.values.where.from.into.of.is.null.as.on.in.select.selectblob.insert.update.updateblob.delete.commit.rollback.connect.disconnect.declare.cursor.procedure.execute.fetch.prepare.describe.immediate.prior.first.last.between.like.exists.having.group.order.union.all.distinct.asc.desc.shared.system.readonly.constant.ref.static.indirect.global.rpcfunc.alias.library.external.native.namespace.enumerated.intrinsic.autoinstantiate.prototype.forward.type.within.true.false.public.private.protected.privateread.privatewrite.protectedread.protectedwrite.systemread.systemwrite".split(".")), qc = new Set(/* @__PURE__ */ "any.blob.boolean.byte.char.character.date.datetime.dec.decimal.double.int.integer.long.longlong.longptr.real.string.time.uint.ulong.unsignedint.unsignedinteger.unsignedlong.transaction.error.message.application.window.menu.datawindow.datastore.datawindowchild.nonvisualobject.function_object.powerobject.oleobject.olecontrol.treeview.listview.tab.graph.groupbox.commandbutton.checkbox.radiobutton.singlelineedit.multilineedit.editmask.richtextedit.statictext.picture.line.rectangle.roundrectangle.oval.hprogressbar.vprogressbar.hscrollbar.vscrollbar.httpclient.restclient.inet.jsonparser.jsongenerator.jsonpackage.pipeline.timing.structure.environment.coderobject.compressorobject.crypterobject.errorlogging.exception.profilercall.profileclass.profileline.profileroutine".split(".")), Jc = new Set(/* @__PURE__ */ "abs.acos.asin.atan.ceiling.cos.exp.fact.log.logten.max.min.mod.pi.rand.randomize.round.sign.sin.sqrt.tan.truncate.string.integer.long.double.dec.date.time.now.today.year.month.day.hour.minute.second.upper.lower.trim.len.pos.right.left.mid.replace.isnull.isvalid.messagebox.triggerevent.classname.upperbound.lowerbound.fileopen.fileclose.fileread.filewrite.fileseek.filelength.fileexists.setnull.setattribute.getitem.retrieve.update.insertrow.deleterow.setrow.getrow.rowcount.accepttext.reset.filter.print.pagesetup.preview.sharedata.settransobject.dataobject".split(".")), Yc = new Set([
	"this",
	"parent",
	"super",
	"parentwindow",
	"sqlca",
	"sqlda",
	"sqlsa",
	"error",
	"message"
]), Xc = {
	keyword: "#c586c0",
	type: "#4ec9b0",
	builtin: "#dcdcaa",
	string: "#ce9178",
	comment: "#6a9955",
	number: "#b5cea8",
	pronoun: "#569cd6",
	enum: "#4fc1ff",
	operator: "#d4d4d4"
};
function Zc(e) {
	return e.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function Qc(e) {
	let t = "", n = 0, r = e.length;
	for (; n < r;) {
		let i = e[n], a = n + 1 < r ? e[n + 1] : void 0;
		if (i === "/" && a === "/") return t + `<span style="color:${Xc.comment}">${Zc(e.slice(n))}</span>`;
		if (i === "/" && a === "*") {
			let r = e.indexOf("*/", n + 2);
			if (r !== -1) {
				t += `<span style="color:${Xc.comment}">${Zc(e.slice(n, r + 2))}</span>`, n = r + 2;
				continue;
			} else return t + `<span style="color:${Xc.comment}">${Zc(e.slice(n))}</span>`;
		}
		if (i === "\"") {
			let i = n + 1;
			for (; i < r;) {
				let t = e[i], n = i + 1 < r ? e[i + 1] : void 0;
				if (t === "~" && n !== void 0) {
					i += 2;
					continue;
				}
				if (t === "\"") {
					i++;
					break;
				}
				i++;
			}
			t += `<span style="color:${Xc.string}">${Zc(e.slice(n, i))}</span>`, n = i;
			continue;
		}
		if (i === "'") {
			let i = n + 1;
			for (; i < r;) {
				let t = e[i], n = i + 1 < r ? e[i + 1] : void 0;
				if (t === "~" && n !== void 0) {
					i += 2;
					continue;
				}
				if (t === "'") {
					i++;
					break;
				}
				i++;
			}
			t += `<span style="color:${Xc.string}">${Zc(e.slice(n, i))}</span>`, n = i;
			continue;
		}
		if (i === "~" && a === "\"") {
			let i = n + 2;
			for (; i < r;) {
				let t = e[i], n = i + 1 < r ? e[i + 1] : void 0;
				if (t === "~" && n === "~") {
					i += 2;
					continue;
				}
				if (t === "~" && n === "\"") {
					i += 2;
					break;
				}
				i++;
			}
			t += `<span style="color:${Xc.string}">${Zc(e.slice(n, i))}</span>`, n = i;
			continue;
		}
		if (/[0-9]/.test(i) && (n === 0 || /[\s(+\-*/^=<>,]/.test(e[n - 1]))) {
			let i = n;
			for (; i < r && /[0-9._eE+-]/.test(e[i]);) i++;
			t += `<span style="color:${Xc.number}">${Zc(e.slice(n, i))}</span>`, n = i;
			continue;
		}
		if (/[A-Za-z_]/.test(i)) {
			let i = n;
			for (; i < r && /[\w$#%\-]/.test(e[i]);) i++;
			let a = e.slice(n, i), o = a.toLowerCase();
			if (i < r && e[i] === "!") {
				t += `<span style="color:${Xc.enum}">${Zc(a)}!</span>`, n = i + 1;
				continue;
			}
			let s = null;
			Kc.has(o) ? s = Xc.keyword : qc.has(o) ? s = Xc.type : Jc.has(o) ? s = Xc.builtin : Yc.has(o) && (s = Xc.pronoun), s ? t += `<span style="color:${s}">${Zc(a)}</span>` : t += Zc(a), n = i;
			continue;
		}
		if (/[<>=+\-*/^]/.test(i)) {
			let i = n + 1;
			n + 1 < r && /=<>>/.test(e[n + 1]) && i++, t += `<span style="color:${Xc.operator}">${Zc(e.slice(n, i))}</span>`, n = i;
			continue;
		}
		t += Zc(i), n++;
	}
	return t;
}
function $c(e) {
	return e.split("\n").map((e) => Qc(e)).join("\n");
}
var el = 200;
function tl(e, t) {
	let n = e.split("\n"), r = 0;
	function i() {
		let e = Math.min(r + el, n.length), a = n.slice(r, e).map((e) => Qc(e)).join("\n");
		r = e, r >= n.length ? t(a, !0) : (t(a, !1), setTimeout(i, 0));
	}
	i();
}
function nl(e) {
	return new Promise((t) => {
		let n = "";
		tl(e, (e, r) => {
			n += e, r && t(n);
		});
	});
}
Wc.registerLanguage("sql", Gc);
function rl(e) {
	return Wc.highlight(e, { language: "sql" }).value;
}
var il = new Set([
	...Kc,
	...Yc,
	"function",
	"subroutine",
	"event",
	"on"
]), al = /*#__PURE__*/ W("<button>"), ol = /*#__PURE__*/ W("<button>View CFG"), sl = /*#__PURE__*/ W("<button>Generate backward slice"), cl = /*#__PURE__*/ W("<button>View taint paths"), ll = /*#__PURE__*/ W("<div class=context-menu style=position:fixed><button>Go to definition");
function ul(e) {
	ae(() => {
		function t(t) {
			t.key === "Escape" && e.onClose();
		}
		document.addEventListener("keydown", t), L(() => document.removeEventListener("keydown", t));
	});
	function t(t) {
		t(), e.onClose();
	}
	return R(H, {
		get when() {
			return e.target;
		},
		children: (n) => {
			let r = () => n().linkType === "procedure", i = () => n().linkName, a = () => e.contextActions, o = () => n().procObject ?? e.objectName, s = () => Math.min(n().x, (typeof window < "u" ? window.innerWidth : 800) - 220), c = () => Math.min(n().y, (typeof window < "u" ? window.innerHeight : 600) - 200);
			return (() => {
				var l = ll(), u = l.firstChild;
				return u.$$click = () => t(() => {
					n().linkType === "procedure" ? e.store.dispatch({
						tag: "objects",
						action: {
							tag: "proc-select",
							objectName: o(),
							procName: i()
						}
					}) : n().linkType === "object" && e.store.dispatch({
						tag: "objects",
						action: {
							tag: "select",
							name: i()
						}
					});
				}), X(l, R(H, {
					get when() {
						return r();
					},
					get children() {
						return [
							(() => {
								var e = al();
								return e.$$click = () => {
									a()?.onFindCallers && t(() => a().onFindCallers(i(), o()));
								}, X(e, () => "Find callers" + (n().callerCount == null ? "" : ` (${n().callerCount})`)), N(() => e.disabled = !a()?.onFindCallers), e;
							})(),
							(() => {
								var e = al();
								return e.$$click = () => {
									a()?.onFindCallees && t(() => a().onFindCallees(i(), o()));
								}, X(e, () => "Find callees" + (n().calleeCount == null ? "" : ` (${n().calleeCount})`)), N(() => e.disabled = !a()?.onFindCallees), e;
							})(),
							(() => {
								var e = ol();
								return e.$$click = () => {
									a()?.onViewCfg && t(() => a().onViewCfg(i(), o()));
								}, N(() => e.disabled = !a()?.onViewCfg), e;
							})(),
							(() => {
								var r = sl();
								return r.$$click = () => t(() => {
									e.store.dispatch({
										tag: "objects",
										action: {
											tag: "go-slice",
											object: o(),
											proc: i(),
											line: n().sourceLine,
											direction: "backward"
										}
									});
								}), r;
							})(),
							(() => {
								var e = cl();
								return e.$$click = () => {
									a()?.onViewTaint && t(() => a().onViewTaint(i(), o()));
								}, N(() => e.disabled = !a()?.onViewTaint), e;
							})()
						];
					}
				}), null), N((e) => {
					var t = `${s()}px`, n = `${c()}px`;
					return t !== e.e && Y(l, "left", e.e = t), n !== e.t && Y(l, "top", e.t = n), e;
				}, {
					e: void 0,
					t: void 0
				}), l;
			})();
		}
	});
}
G(["click"]);
//#endregion
//#region src/components/source/pure/tooltip.ts
var dl = {
	function: "proc-function",
	subroutine: "proc-subroutine",
	event: "proc-event",
	on: "proc-on"
}, fl = {
	function: "#a78bfa",
	subroutine: "#fb923c",
	event: "#facc15",
	on: "#4ade80"
};
function pl(e, t) {
	let n = t?.kind ?? "object", r = n === "datawindow" ? "#56A85D" : "#5B8DD9";
	return {
		color: r,
		html: `<div class="tt-name" style="color:${r}">${e}</div><div class="tt-meta">${n}</div>`
	};
}
function ml(e, t, n) {
	let r = t ? fl[t.proc_type] ?? "#a78bfa" : "#a78bfa", i = `<div class="tt-name" style="color:${r}">${e}</div>`;
	if (t) {
		let e = t.return_type ? ` → ${t.return_type}` : "";
		i += `<div class="tt-meta">${t.proc_type}${e}</div>`, t.params && (i += `<div class="tt-meta">(${t.params})</div>`), i += `<div class="tt-meta">${t.object}</div>`, t.cyclomatic != null && (i += `<div class="tt-cc"><span class="badge badge-cc">CC: ${t.cyclomatic}</span></div>`), n && (i += `<div class="tt-meta">Callers: ${n.caller_count} · Callees: ${n.callee_count}</div>`);
	}
	return {
		color: r,
		html: i
	};
}
function hl(e, t) {
	if (!t) return null;
	let n = t.is_parameter ? "#4fc1ff" : "#9cdcfe", r = t.is_parameter ? "<span class=\"badge badge-param\">param</span>" : "<span class=\"badge badge-var\">local</span>", i = t.resolved_kind === "object" ? "#5B8DD9" : t.resolved_kind === "primitive" ? "#4ec9b0" : "#9cdcfe", a = `<div class="tt-name" style="color:${n}">${e}</div>`;
	return a += `<div class="tt-meta" style="color:${i}">${t.raw_type}</div>`, a += `<div class="tt-cc">${r}</div>`, t.resolved_target && (a += `<div class="tt-meta" style="color:#5B8DD9">${t.resolved_target}</div>`), {
		color: n,
		html: a
	};
}
function gl(e, t, n, r) {
	let i = e.owner && e.owner !== r ? `${e.owner} · ${e.name}` : e.name, a = e.cyclomatic == null ? "" : `CC: ${e.cyclomatic}`, o = e.return_type ? ` → ${e.return_type}` : "";
	return `<div class="tt-name" style="color:${n}">${i}</div><div class="tt-meta">${e.proc_type} ${e.modifiers ?? ""}${o}</div>` + (e.params ? `<div class="tt-meta">(${e.params})</div>` : "") + `<div class="tt-meta">Lines ${e.start_line}–${e.end_line}</div>` + (a ? `<div class="tt-cc"><span class="badge badge-cc">${a}</span></div>` : "") + (t ? `<div class="tt-meta">Callers: ${t.caller_count} · Callees: ${t.callee_count}</div>` : "");
}
//#endregion
//#region src/components/source/SourceGutter.tsx
var _l = /*#__PURE__*/ W("<div class=source-gutter>"), vl = /*#__PURE__*/ W("<div class=source-gutter-line>");
function yl(e) {
	return (() => {
		var t = _l();
		return X(t, R(V, {
			get each() {
				return e.lines;
			},
			children: (t, n) => {
				let r = n() + 1, i = e.procFirstLine.get(r);
				return (() => {
					var e = vl();
					return X(e, () => String(r)), N((t) => ct(e, i ? {
						color: fl[i.proc_type ?? ""] ?? "var(--text-muted)",
						"font-weight": "600"
					} : void 0, t)), e;
				})();
			}
		})), t;
	})();
}
//#endregion
//#region src/components/source/pure/line.ts
var bl = 20.8;
function xl(e, t, n) {
	return Math.max(1, 1 + Math.floor((e - t + n) / bl));
}
function Sl(e) {
	return (e - 1) * bl;
}
function Cl(e, t) {
	return (t - e + 1) * bl;
}
function wl(e, t) {
	if (!t) return null;
	let n = e.find((e) => e.name === t);
	return !n || n.start_line == null || n.end_line == null ? null : {
		start: n.start_line,
		end: n.end_line
	};
}
//#endregion
//#region src/components/source/ProcOverlayBars.tsx
var Tl = /*#__PURE__*/ W("<div>");
function El(e) {
	return R(V, {
		get each() {
			return e.procedures;
		},
		children: (t) => {
			if (t.start_line == null || t.end_line == null) return null;
			let n = dl[t.proc_type ?? ""] ?? "", r = () => t.name === e.selectedProcName;
			return (() => {
				var i = Tl();
				return i.$$click = () => e.onClick(t), i.addEventListener("mouseleave", () => e.onBarLeave()), i.addEventListener("mouseenter", (n) => e.onBarEnter(t, n)), N((e) => {
					var a = `source-proc-bar ${n}${r() ? " selected" : ""}`, o = `${Sl(t.start_line)}px`, s = `${Cl(t.start_line, t.end_line)}px`;
					return a !== e.e && q(i, e.e = a), o !== e.t && Y(i, "top", e.t = o), s !== e.a && Y(i, "height", e.a = s), e;
				}, {
					e: void 0,
					t: void 0,
					a: void 0
				}), i;
			})();
		}
	});
}
G(["click"]);
//#endregion
//#region src/components/source/SourceTooltip.tsx
var Dl = /*#__PURE__*/ W("<div class=\"source-proc-tooltip visible\">");
function Ol(e) {
	return R(H, {
		get when() {
			return e.tooltip;
		},
		get children() {
			var t = Dl();
			return N((n) => {
				var r = `${Math.min(e.tooltip.x, window.innerWidth - 420)}px`, i = `${Math.min(e.tooltip.y, window.innerHeight - 140)}px`, a = e.tooltip.html;
				return r !== n.e && Y(t, "left", n.e = r), i !== n.t && Y(t, "top", n.t = i), a !== n.a && (t.innerHTML = n.a = a), n;
			}, {
				e: void 0,
				t: void 0,
				a: void 0
			}), t;
		}
	});
}
//#endregion
//#region src/components/source/pure/identifiers.ts
function kl(e, t, n, r, i) {
	return e.replace(/\b([A-Za-z_][\w$#%-]*)\b/g, (e, a) => {
		let o = a.toLowerCase();
		return o === i.toLowerCase() || il.has(o) ? e : n.has(o) ? `<span class="src-link src-link-proc" data-link-type="procedure" data-link-name="${a}">${e}</span>` : r.has(o) ? `<span class="src-link ${r.get(o).is_parameter ? "src-link-param" : "src-link-var"}" data-link-type="var" data-link-name="${a}">${e}</span>` : t.has(o) ? `<span class="src-link src-link-obj" data-link-type="object" data-link-name="${a}">${e}</span>` : e;
	});
}
//#endregion
//#region src/components/source/pure/lookup.ts
function Al(e) {
	let t = /* @__PURE__ */ new Map();
	for (let n of e) t.set(n.name.toLowerCase(), n);
	return t;
}
function jl(e, t, n) {
	let r = /* @__PURE__ */ new Map();
	for (let t of e) r.set(t.name.toLowerCase(), t);
	for (let e of t) r.set(e.name.toLowerCase(), {
		name: e.name,
		object: n,
		proc_type: e.proc_type,
		modifiers: e.modifiers,
		params: e.params,
		return_type: e.return_type,
		start_line: e.start_line,
		end_line: e.end_line,
		cyclomatic: e.cyclomatic
	});
	return r;
}
function Ml(e) {
	let t = /* @__PURE__ */ new Map();
	for (let n of e) {
		let e = n.var_name.toLowerCase();
		t.has(e) || t.set(e, n);
	}
	return t;
}
function Nl(e) {
	let t = /* @__PURE__ */ new Map();
	for (let n of e) t.set(n.name.toLowerCase(), {
		caller_count: n.caller_count ?? 0,
		callee_count: n.callee_count ?? 0
	});
	return t;
}
function Pl(e) {
	let t = /* @__PURE__ */ new Map();
	for (let n of e) n.start_line != null && t.set(n.start_line, n);
	return t;
}
//#endregion
//#region src/components/source/SourceViewer.tsx
var Fl = /*#__PURE__*/ W("<div class=source-proc-range-bg>"), Il = /*#__PURE__*/ W("<div class=source-viewer><div class=source-code-area><pre>");
function Ll(e) {
	let t = e.store, [n, r] = j(null), [i, a] = j(null), o;
	P(() => {
		!f() || !o || o.scrollIntoView({
			behavior: "instant",
			block: "start"
		});
	});
	let s = F(() => Al(e.knownObjects)), c = F(() => jl(e.knownProcs, e.procedures, e.objectName)), l = F(() => Ml(e.localSymbols ?? [])), u = F(() => Nl(e.procedures)), d = F(() => Pl(e.procedures)), f = F(() => wl(e.procedures, e.selectedProcName)), p = F(() => $c(e.lines.join("\n")).split("\n").map((t) => kl(t, s(), c(), l(), e.objectName)).join("\n"));
	function m(e) {
		let t = e.target.closest("[data-link-type]");
		if (!t) {
			r(null);
			return;
		}
		let { linkType: n, linkName: i } = t.dataset;
		if (!n || !i) return;
		let a = i.toLowerCase();
		if (n === "object") {
			let n = pl(i, s().get(a));
			t.style.color = n.color, r({
				html: n.html,
				x: e.clientX + 12,
				y: e.clientY + 12
			});
		} else if (n === "procedure") {
			let n = ml(i, c().get(a), u().get(a));
			t.style.color = n.color, r({
				html: n.html,
				x: e.clientX + 12,
				y: e.clientY + 12
			});
		} else if (n === "var") {
			let n = l().get(a);
			t.style.color = n?.is_parameter ? "#4fc1ff" : "#9cdcfe";
			let o = hl(i, n);
			o && r({
				html: o.html,
				x: e.clientX + 12,
				y: e.clientY + 12
			});
		}
	}
	function h(e) {
		let t = e.target.closest("[data-link-type]");
		t && (t.style.color = ""), e.relatedTarget?.closest("[data-link-type]") || r(null);
	}
	function g(e) {
		let n = e.target.closest("[data-link-type]");
		if (!n) return;
		let { linkType: r, linkName: i } = n.dataset;
		if (!(!r || !i)) {
			if (r === "object") t.dispatch({
				tag: "objects",
				action: {
					tag: "select",
					name: i
				}
			});
			else if (r === "procedure") {
				let e = c().get(i.toLowerCase());
				t.dispatch(e ? {
					tag: "objects",
					action: {
						tag: "proc-select",
						objectName: e.object,
						procName: e.name
					}
				} : {
					tag: "objects",
					action: {
						tag: "select",
						name: i
					}
				});
			}
		}
	}
	function _(e) {
		e.preventDefault();
		let t = e.target.closest("[data-link-type]");
		if (!t) {
			a(null);
			return;
		}
		let n = t.dataset.linkType ?? "var", r = t.dataset.linkName;
		if (!r) return;
		let i = r.toLowerCase(), o = n === "procedure" ? c().get(i) : void 0, s = n === "procedure" ? u().get(i) : void 0, l = e.currentTarget;
		a({
			linkType: n,
			linkName: r,
			x: e.clientX,
			y: e.clientY,
			sourceLine: xl(e.clientY, l.getBoundingClientRect().top, l.scrollTop),
			callerCount: s?.caller_count,
			calleeCount: s?.callee_count,
			procObject: o?.object
		});
	}
	return (() => {
		var s = Il(), c = s.firstChild, l = c.firstChild;
		return X(s, R(yl, {
			get lines() {
				return e.lines;
			},
			get procFirstLine() {
				return d();
			}
		}), c), c.$$contextmenu = _, c.$$click = g, c.$$mouseout = h, c.$$mouseover = m, X(c, R(H, {
			get when() {
				return f();
			},
			get children() {
				var e = Fl(), t = o;
				return typeof t == "function" ? ut(t, e) : o = e, N((t) => {
					var n = `${Sl(f().start)}px`, r = `${Cl(f().start, f().end)}px`;
					return n !== t.e && Y(e, "top", t.e = n), r !== t.t && Y(e, "height", t.t = r), t;
				}, {
					e: void 0,
					t: void 0
				}), e;
			}
		}), l), X(c, R(El, {
			get procedures() {
				return e.procedures;
			},
			get selectedProcName() {
				return e.selectedProcName;
			},
			get procCountMap() {
				return u();
			},
			onBarEnter: (t, n) => r({
				html: gl(t, u().get(t.name.toLowerCase()), fl[t.proc_type ?? ""] ?? "#fff", e.objectName),
				x: n.clientX + 12,
				y: n.clientY + 12
			}),
			onBarLeave: () => r(null),
			onClick: (n) => e.onProcBarClick ? e.onProcBarClick(n) : t.dispatch({
				tag: "objects",
				action: {
					tag: "proc-select",
					objectName: e.objectName,
					procName: n.name
				}
			})
		}), null), X(s, R(Ol, { get tooltip() {
			return n();
		} }), null), X(s, R(ul, {
			get target() {
				return i();
			},
			store: t,
			get objectName() {
				return e.objectName;
			},
			get contextActions() {
				return e.contextActions;
			},
			onClose: () => a(null)
		}), null), N(() => l.innerHTML = p()), s;
	})();
}
G([
	"mouseover",
	"mouseout",
	"click",
	"contextmenu"
]);
//#endregion
//#region src/features/objects/detail/SourceCard.tsx
var Rl = /*#__PURE__*/ W("<div class=card><div class=source-file-header><div class=card-header><h3>Source</h3></div><div class=source-file-path>"), zl = /*#__PURE__*/ W("<p style=color:var(--red);font-size:12px>"), Bl = /*#__PURE__*/ W("<p style=color:var(--text-muted);font-size:12px>Source not available — re-index to restore it.");
function Vl(e) {
	let t = () => {
		let t = e.sourceDetail;
		return t && "lines" in t && t.lines && t.lines.length > 0;
	};
	return (() => {
		var n = Rl(), r = n.firstChild.firstChild.nextSibling;
		return X(r, () => e.file), X(n, R(H, {
			get when() {
				return t();
			},
			get fallback() {
				return R(H, {
					get when() {
						return e.sourceDetail;
					},
					get children() {
						return U(() => "error" in e.sourceDetail)() ? (() => {
							var t = zl();
							return X(t, () => e.sourceDetail.error), t;
						})() : Bl();
					}
				});
			},
			get children() {
				return R(Ll, {
					get store() {
						return e.store;
					},
					get lines() {
						return e.sourceDetail.lines;
					},
					get procedures() {
						return e.sourceDetail.procedures;
					},
					get knownObjects() {
						return e.sourceDetail.knownObjects;
					},
					get knownProcs() {
						return e.sourceDetail.knownProcs;
					},
					get localSymbols() {
						return e.sourceDetail.localSymbols;
					},
					get objectName() {
						return e.objectName;
					},
					get selectedProcName() {
						return e.selectedProcName;
					},
					get contextActions() {
						return e.contextActions;
					}
				});
			}
		}), null), n;
	})();
}
//#endregion
//#region src/components/detail/AnalysisSummaryBar.tsx
var Hl = /*#__PURE__*/ W("<div class=analysis-summary-bar style=\"display:flex;flex-wrap:wrap;gap:6px;padding:8px 0\">"), Ul = /*#__PURE__*/ W("<button>"), Wl = /*#__PURE__*/ W("<span class=filter-pill style=cursor:default>");
function Gl(e) {
	return (() => {
		var t = Hl();
		return X(t, R(V, {
			get each() {
				return e.items;
			},
			children: (e) => R(H, {
				get when() {
					return e.onClick;
				},
				get fallback() {
					return (() => {
						var t = Wl();
						return X(t, () => e.label, null), X(t, (() => {
							var t = U(() => e.count != null);
							return () => t() ? ` (${e.count})` : "";
						})(), null), t;
					})();
				},
				get children() {
					var t = Ul();
					return J(t, "click", e.onClick, !0), X(t, () => e.label, null), X(t, (() => {
						var t = U(() => e.count != null);
						return () => t() ? ` (${e.count})` : "";
					})(), null), N(() => q(t, `filter-pill${e.active ? " active" : ""}`)), t;
				}
			})
		})), t;
	})();
}
G(["click"]);
//#endregion
//#region src/components/detail/ContextualPanel.tsx
var Kl = /*#__PURE__*/ W("<div class=card style=margin-top:12px><div class=card-header style=display:flex;align-items:center;gap:8px><h3 style=flex:1;margin:0></h3><button aria-label=\"Close panel\"style=\"background:none;border:none;cursor:pointer;color:var(--text-muted);font-size:16px;padding:0 4px;line-height:1\">✕</button></div><div>");
function ql(e) {
	return (() => {
		var t = Kl(), n = t.firstChild, r = n.firstChild, i = r.nextSibling, a = n.nextSibling;
		return X(r, () => e.title), J(i, "click", e.onClose, !0), X(a, () => e.children), t;
	})();
}
G(["click"]);
//#endregion
//#region src/features/analysis/CFGCore.tsx
var Jl = /*#__PURE__*/ W("<div class=cfg-source-excerpt><div class=cfg-excerpt-gutter></div><div class=cfg-excerpt-code><pre>"), Yl = /*#__PURE__*/ W("<div class=cfg-excerpt-gutter-line>"), Xl = /*#__PURE__*/ W("<div>"), Zl = /*#__PURE__*/ W("<div class=cfg-block-panel><div class=cfg-block-panel-header></div><div class=cfg-block-panel-body>"), Ql = /*#__PURE__*/ W("<p class=cfg-block-empty>Hover or click a node to inspect it."), $l = /*#__PURE__*/ W("<p class=cfg-block-meta>Lines <!>&ndash;"), eu = /*#__PURE__*/ W("<button class=cfg-block-goto>↗ "), tu = /*#__PURE__*/ W("<div class=cfg-block-stmt>"), nu = /*#__PURE__*/ W("<div class=diagram-container><div class=loading-overlay><div class=spinner></div> Loading CFG…"), ru = /*#__PURE__*/ W("<div class=diagram-container><div class=loading-overlay style=color:var(--red)>CFG unavailable — procedure not found or has no body."), iu = /*#__PURE__*/ W("<div class=\"source-proc-tooltip visible\">"), au = /*#__PURE__*/ W("<div class=cfg-split><div class=cfg-diagram-pane><div><div class=diagram-toolbar><button class=icon-btn title=\"Zoom out\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M4 8h8\"stroke=currentColor stroke-width=1.5 stroke-linecap=round></path></svg></button><span class=diagram-zoom-label>%</span><button class=icon-btn title=\"Zoom in\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M8 4v8M4 8h8\"stroke=currentColor stroke-width=1.5 stroke-linecap=round></path></svg></button><button class=\"icon-btn reset-btn\"title=\"Fit to viewport (F)\">Fit</button><button class=\"icon-btn reset-btn\"title=\"Reset zoom (R)\">1:1</button></div><div class=diagram-svg-wrap></div></div></div><div class=cfg-resize-handle></div><div style=flex-shrink:0;display:flex;flex-direction:column;min-height:0>"), ou = { unreachable: "#facc15" }, su = { unreachable: "0.4" }, cu = {
	"taint-entering": "#f59e0b",
	"proven-safe": "#6366f1"
}, lu = { unreachable: "4 2" };
function uu(e, t) {
	for (let { blockId: n, state: r } of t) {
		if (r === "default") continue;
		let t = e.querySelector(`[id="${n}"]`);
		if (!t) continue;
		let i = t.querySelector("polygon, ellipse, path");
		if (!i) continue;
		let a = ou[r];
		a && i.setAttribute("fill", a);
		let o = su[r];
		o && i.setAttribute("fill-opacity", o);
		let s = cu[r];
		s && (i.setAttribute("stroke", s), i.setAttribute("stroke-width", "2"));
		let c = lu[r];
		c && i.setAttribute("stroke-dasharray", c);
	}
}
var du = 3;
function fu(e) {
	let t = F(() => {
		let t = e.block, n = e.sourceLines;
		if (!t || !t.firstLine || !t.lastLine || n.length === 0) return null;
		let r = t.firstLine - e.procStartLine, i = t.lastLine - e.procStartLine;
		if (r < 0 || r >= n.length) return null;
		let a = Math.max(0, r - du), o = Math.min(n.length - 1, i + du);
		return {
			lines: $c(n.slice(a, o + 1).join("\n")).split("\n"),
			winStart: a,
			highlightRel0: r,
			highlightRel1: i
		};
	});
	return R(H, {
		get when() {
			return t();
		},
		children: (t) => (() => {
			var n = Jl(), r = n.firstChild, i = r.nextSibling.firstChild;
			return X(r, R(V, {
				get each() {
					return t().lines;
				},
				children: (n, r) => {
					let i = e.procStartLine + t().winStart + r();
					return (() => {
						var e = Yl();
						return X(e, i), e;
					})();
				}
			})), X(i, R(V, {
				get each() {
					return t().lines;
				},
				children: (e, n) => {
					let r = t().winStart + n(), i = r >= t().highlightRel0 && r <= t().highlightRel1;
					return (() => {
						var t = Xl();
						return q(t, i ? "cfg-excerpt-line cfg-excerpt-highlight" : "cfg-excerpt-line cfg-excerpt-context"), t.innerHTML = e, t;
					})();
				}
			})), n;
		})()
	});
}
function pu(e) {
	return (() => {
		var t = Zl(), n = t.firstChild, r = n.nextSibling;
		return X(n, (() => {
			var t = U(() => !!e.block);
			return () => t() ? `Block ${e.block.blockId}` : "Hover a node";
		})()), X(r, R(H, {
			get when() {
				return e.block;
			},
			get fallback() {
				return Ql();
			},
			children: (t) => [
				(() => {
					var e = $l(), n = e.firstChild.nextSibling;
					return n.nextSibling, X(e, () => t().firstLine ?? "?", n), X(e, () => t().lastLine ?? "?", null), e;
				})(),
				R(V, {
					get each() {
						return t().stmts;
					},
					children: (e) => (() => {
						var t = tu();
						return X(t, e), t;
					})()
				}),
				R(fu, {
					get block() {
						return t();
					},
					get sourceLines() {
						return e.sourceLines;
					},
					get procStartLine() {
						return e.procStartLine;
					}
				}),
				(() => {
					var t = eu();
					return t.firstChild, J(t, "click", e.onGoto, !0), X(t, () => e.gotoLabel, null), t;
				})()
			]
		})), t;
	})();
}
var mu = 180, hu = 600, gu = 300;
function _u(e) {
	let [t, n] = j(null), [r, i] = j(null), [a, o] = j(gu), s, c, l = Ts({ dismissTooltip: () => {} });
	L(() => {
		l.cleanup(), l.removeViewportRef();
	});
	let [u] = re(() => `${e.object}::${e.proc}`, async () => {
		n(null);
		let t = `/api/diagrams/cfg/${encodeURIComponent(e.object)}/${encodeURIComponent(e.proc)}`, r = await fetch(t);
		if (!r.ok) throw Error(`HTTP ${r.status}`);
		return r.json();
	}), d = F(() => {
		let e = u();
		return e?.sourceOriginal ? e.sourceOriginal.split("\n") : [];
	}), f = F(() => u()?.procStartLine ?? 1);
	function p(e) {
		return u()?.blocks.find((t) => t.blockId === e) ?? null;
	}
	function m(e) {
		if (l.state.dragging() || l.state.momentum()) return;
		let t = e.target.closest("g[id]");
		if (!t) {
			n(null);
			return;
		}
		n(p(t.id));
	}
	function h(t) {
		t.target.closest("g[id]") && e.onGoto();
	}
	function g(e) {
		if (l.state.dragging() || l.state.momentum()) {
			i(null);
			return;
		}
		let t = e.target.closest("g[id]");
		if (!t) {
			i(null);
			return;
		}
		let r = p(t.id);
		if (r && n(r), r) {
			let t = r.stmts.map((e) => `<div class="tt-meta">${e}</div>`).join("") || "<div class=\"tt-meta\">(empty block)</div>";
			i({
				html: `<div class="tt-name">Block ${r.blockId}</div><div class="tt-meta" style="margin-bottom:4px">L${r.firstLine ?? "?"}–L${r.lastLine ?? "?"}</div>` + t,
				x: e.clientX + 14,
				y: e.clientY + 14
			});
		} else i(null);
	}
	function _() {
		i(null);
	}
	function v() {
		if (!s || !c) return;
		let e = s.clientWidth, t = s.clientHeight, n = c.scrollWidth, r = c.scrollHeight;
		if (n <= 0 || r <= 0) return;
		let i = Math.min(e / n, t / r, 1) * .9;
		l.actions.setView(i, (e - n * i) / 2, (t - r * i) / 2);
	}
	function y(e) {
		e.preventDefault();
		let t = e.clientX, n = a();
		function r(e) {
			o(Math.max(mu, Math.min(hu, n - (e.clientX - t))));
		}
		function i() {
			document.removeEventListener("mousemove", r), document.removeEventListener("mouseup", i);
		}
		document.addEventListener("mousemove", r), document.addEventListener("mouseup", i);
	}
	return ae(() => {
		function e(e) {
			let t = e.target;
			t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable || ((e.key === "f" || e.key === "F") && (e.preventDefault(), v()), (e.key === "r" || e.key === "R") && (e.preventDefault(), l.actions.resetView()));
		}
		document.addEventListener("keydown", e), L(() => document.removeEventListener("keydown", e));
	}), [
		R(H, {
			get when() {
				return u.loading;
			},
			get children() {
				return nu();
			}
		}),
		R(H, {
			get when() {
				return u.error;
			},
			get children() {
				var e = ru();
				return e.firstChild, e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !u.loading && !u.error)() && u();
			},
			children: (n) => (() => {
				var i = au(), o = i.firstChild, u = o.firstChild, p = u.firstChild, b = p.firstChild, x = b.nextSibling, ee = x.firstChild, S = x.nextSibling, C = S.nextSibling, w = C.nextSibling, T = p.nextSibling, E = o.nextSibling, D = E.nextSibling;
				return J(u, "mouseleave", l.handlers.onMouseLeave), J(u, "mouseup", l.handlers.onMouseUp, !0), J(u, "mousemove", l.handlers.onMouseMove, !0), J(u, "mousedown", l.handlers.onMouseDown, !0), ut((e) => {
					s = e, l.setViewportRef(e);
				}, u), J(b, "click", l.actions.zoomOut, !0), X(x, () => Math.round(l.state.scale() * 100), ee), J(S, "click", l.actions.zoomIn, !0), C.$$click = v, J(w, "click", l.actions.resetView, !0), T.addEventListener("mouseleave", _), T.$$mousemove = g, T.$$dblclick = h, T.$$click = m, ut((e) => {
					c = e, requestAnimationFrame(() => {
						uu(e, n().nodeStates), v();
					});
				}, T), E.$$mousedown = y, X(D, R(pu, {
					get block() {
						return t();
					},
					get sourceLines() {
						return d();
					},
					get procStartLine() {
						return f();
					},
					get onGoto() {
						return e.onGoto;
					},
					get gotoLabel() {
						return e.gotoLabel ?? "View full procedure";
					}
				})), X(i, R(H, {
					get when() {
						return r();
					},
					get children() {
						var e = iu();
						return N((t) => {
							var n = `${Math.min(r().x, window.innerWidth - 300)}px`, i = `${Math.min(r().y, window.innerHeight - 160)}px`, a = r().html;
							return n !== t.e && Y(e, "left", t.e = n), i !== t.t && Y(e, "top", t.t = i), a !== t.a && (e.innerHTML = t.a = a), t;
						}, {
							e: void 0,
							t: void 0,
							a: void 0
						}), e;
					}
				}), null), N((e) => {
					var t = l.state.dragging() ? "diagram-viewport grabbing" : "diagram-viewport", r = `translate(${l.state.offset().x}px, ${l.state.offset().y}px) scale(${l.state.scale()})`, i = n().svg, o = `${a()}px`;
					return t !== e.e && q(u, e.e = t), r !== e.t && Y(T, "transform", e.t = r), i !== e.a && (T.innerHTML = e.a = i), o !== e.o && Y(D, "width", e.o = o), e;
				}, {
					e: void 0,
					t: void 0,
					a: void 0,
					o: void 0
				}), i;
			})()
		})
	];
}
G([
	"click",
	"mousedown",
	"mousemove",
	"mouseup",
	"dblclick"
]);
//#endregion
//#region src/components/controls/StaticText.tsx
var vu = /*#__PURE__*/ W("<div class=control-statictext style=\"font-size:calc(11px / var(--canvas-scale, 1));color:var(--text);padding:2px 4px;white-space:nowrap;overflow:hidden\">");
function yu(e) {
	return (() => {
		var t = vu();
		return X(t, () => e.ctrl.text ?? ""), t;
	})();
}
//#endregion
//#region src/components/controls/CommandButton.tsx
var bu = /*#__PURE__*/ W("<button class=control-commandbutton style=\"width:100%;height:100%;font-size:calc(11px / var(--canvas-scale, 1));cursor:pointer;border:1px solid var(--border);background:var(--surface-raised);color:var(--text);padding:2px 6px;box-sizing:border-box\">");
function xu(e) {
	return (() => {
		var t = bu();
		return J(t, "click", e.onClick, !0), X(t, () => e.ctrl.text ?? e.ctrl.name), t;
	})();
}
G(["click"]);
//#endregion
//#region src/components/controls/GroupBox.tsx
var Su = /*#__PURE__*/ W("<fieldset class=control-groupbox style=\"width:100%;height:100%;font-size:calc(11px / var(--canvas-scale, 1));border:1px solid var(--border);padding:4px;box-sizing:border-box\"><legend style=\"font-size:calc(11px / var(--canvas-scale, 1));color:var(--text-muted);padding:0 4px\">");
function Cu(e) {
	return (() => {
		var t = Su(), n = t.firstChild;
		return X(n, () => e.ctrl.text ?? ""), t;
	})();
}
//#endregion
//#region src/components/controls/LineEdit.tsx
var wu = /*#__PURE__*/ W("<textarea class=control-multilineedit readonly style=\"width:100%;height:100%;font-size:11px;border:1px solid var(--border);background:var(--surface);color:var(--text);padding:2px 4px;resize:none;box-sizing:border-box\">"), Tu = /*#__PURE__*/ W("<input class=control-singlelineedit type=text readonly style=\"width:100%;height:100%;font-size:11px;border:1px solid var(--border);background:var(--surface);color:var(--text);padding:2px 4px;box-sizing:border-box\">");
function Eu(e) {
	return e.ctrl.type.toLowerCase().includes("multi") ? (() => {
		var t = wu();
		return N(() => t.value = e.ctrl.text ?? ""), t;
	})() : (() => {
		var t = Tu();
		return N(() => t.value = e.ctrl.text ?? ""), t;
	})();
}
//#endregion
//#region src/components/DataWindowGrid.tsx
var Du = /*#__PURE__*/ W("<table class=data-table style=font-size:12px;width:100%><thead><tr></tr></thead><tbody>"), Ou = /*#__PURE__*/ W("<div class=dw-grid-container style=overflow-x:auto>"), ku = /*#__PURE__*/ W("<div style=padding:8px;color:var(--text-muted);font-size:12px>No data"), Au = /*#__PURE__*/ W("<th style=\"text-align:left;padding:4px 8px\">"), ju = /*#__PURE__*/ W("<tr>"), Mu = /*#__PURE__*/ W("<td style=\"padding:4px 8px\">");
function Nu(e) {
	let t = () => e.columns || (e.data.length > 0 ? Object.keys(e.data[0]) : []);
	return (() => {
		var n = Ou();
		return X(n, R(H, {
			get when() {
				return e.data.length > 0;
			},
			get fallback() {
				return ku();
			},
			get children() {
				var n = Du(), r = n.firstChild, i = r.firstChild, a = r.nextSibling;
				return X(i, R(V, {
					get each() {
						return t();
					},
					children: (e) => (() => {
						var t = Au();
						return X(t, e), t;
					})()
				})), X(a, R(V, {
					get each() {
						return e.data;
					},
					children: (n, r) => (() => {
						var i = ju();
						return X(i, R(V, {
							get each() {
								return t();
							},
							children: (t) => (() => {
								var i = Mu();
								return i.$$click = () => e.onCellClick?.(r(), t, n[t]), X(i, () => String(n[t] ?? "")), N((t) => Y(i, "cursor", e.onCellClick ? "pointer" : void 0)), i;
							})()
						})), i;
					})()
				})), n;
			}
		})), n;
	})();
}
G(["click"]);
//#endregion
//#region src/components/ResizableCanvas.tsx
var Pu = /*#__PURE__*/ W("<div><div style=\"overflow:hidden;position:relative;border:1px solid #ccc\"><div style=\"transform-origin:top left;position:relative\"></div><div style=position:absolute;top:0;right:0;width:6px;height:100%;cursor:ew-resize;z-index:10></div><div style=position:absolute;bottom:0;left:0;width:100%;height:6px;cursor:ns-resize;z-index:10></div><div style=position:absolute;bottom:0;right:0;width:12px;height:12px;cursor:nwse-resize;z-index:10>");
function Fu(e) {
	let t, [n, r] = j(e.naturalWidth * e.baseScale), [i, a] = j(e.naturalHeight * e.baseScale), o = () => e.naturalWidth * e.baseScale, s = () => e.naturalHeight * e.baseScale;
	ae(() => {
		if (!t) return;
		let e = t.parentElement;
		function n(e) {
			let t = s(), n = o();
			r(Math.max(200, e)), a(Math.max(120, n > 0 ? Math.round(e / n * t) : 120));
		}
		e && n(Math.max(200, e.clientWidth - 2));
		let i = new ResizeObserver(([e]) => {
			if (!e || l()) return;
			let t = e.contentRect.width - 2;
			t > 0 && n(t);
		});
		e && i.observe(e), L(() => i.disconnect());
	});
	let c = () => {
		let e = o();
		return e === 0 || n() === 0 ? 1 : n() / e;
	}, [l, u] = j(!1);
	function d(e, t) {
		t.preventDefault();
		let o = t.clientX, s = t.clientY, c = n(), l = i();
		u(!0), document.body.style.userSelect = "none";
		function d(t) {
			let n = t.clientX - o, i = t.clientY - s;
			(e === "x" || e === "xy") && r(Math.max(200, c + n)), (e === "y" || e === "xy") && a(Math.max(120, l + i));
		}
		function f() {
			u(!1), document.body.style.userSelect = "", document.removeEventListener("mousemove", d), document.removeEventListener("mouseup", f);
		}
		document.addEventListener("mousemove", d), document.addEventListener("mouseup", f);
	}
	return (() => {
		var r = Pu(), a = r.firstChild, l = a.firstChild, u = l.nextSibling, f = u.nextSibling, p = f.nextSibling, m = t;
		return typeof m == "function" ? ut(m, r) : t = r, X(l, () => e.children), u.$$mousedown = (e) => d("x", e), f.$$mousedown = (e) => d("y", e), p.$$mousedown = (e) => d("xy", e), N((e) => {
			var t = {
				position: "relative",
				"--canvas-scale": `${c()}`
			}, u = `${n()}px`, d = `${i()}px`, f = `${o()}px`, p = `${s()}px`, m = `scale(${c()})`;
			return e.e = ct(r, t, e.e), u !== e.t && Y(a, "width", e.t = u), d !== e.a && Y(a, "height", e.a = d), f !== e.o && Y(l, "width", e.o = f), p !== e.i && Y(l, "height", e.i = p), m !== e.n && Y(l, "transform", e.n = m), e;
		}, {
			e: void 0,
			t: void 0,
			a: void 0,
			o: void 0,
			i: void 0,
			n: void 0
		}), r;
	})();
}
G(["mousedown"]);
//#endregion
//#region src/components/runtime/RuntimeView.tsx
var Iu = /*#__PURE__*/ W("<div class=runtime-ctrl>"), Lu = /*#__PURE__*/ W("<div style=font-size:9px;color:var(--text-muted);margin-top:2px>[<!>]"), Ru = /*#__PURE__*/ W("<div style=font-size:9px>"), zu = /*#__PURE__*/ W("<div class=runtime-control style=\"border:1px solid var(--border);padding:2px 4px;font-size:10px;cursor:pointer;box-sizing:border-box;color:var(--text-muted)\"><span style=font-weight:600;color:var(--text)>"), Bu = /*#__PURE__*/ W("<div class=card style=\"margin-top:8px;padding:8px 12px\"><div style=font-size:11px;font-weight:600;margin-bottom:4px;color:var(--text-muted)>Runtime State</div><table class=data-table style=font-size:11px><tbody>"), Vu = /*#__PURE__*/ W("<tr><td style=color:var(--text-muted);padding-right:12px></td><td>"), Hu = /*#__PURE__*/ W("<div style=color:var(--text-muted);font-size:13px>No AST data available."), Uu = /*#__PURE__*/ W("<div class=runtime-view>"), Wu = .08;
function Gu(e, t) {
	let n = e.type.toLowerCase();
	return n === "statictext" ? (() => {
		var t = Iu();
		return X(t, R(yu, { ctrl: e })), N((n) => ct(t, Ku(e), n)), t;
	})() : n === "commandbutton" ? (() => {
		var n = Iu();
		return X(n, R(xu, {
			ctrl: e,
			onClick: t
		})), N((t) => ct(n, Ku(e), t)), n;
	})() : n === "groupbox" ? (() => {
		var t = Iu();
		return X(t, R(Cu, { ctrl: e })), N((n) => ct(t, Ku(e), n)), t;
	})() : n === "singlelineedit" || n === "multilineedit" ? (() => {
		var t = Iu();
		return X(t, R(Eu, { ctrl: e })), N((n) => ct(t, Ku(e), n)), t;
	})() : R(qu, {
		ctrl: e,
		onClick: t
	});
}
function Ku(e) {
	return {
		position: "absolute",
		left: `${e.x * Wu}px`,
		top: `${e.y * Wu}px`,
		width: `${e.width * Wu}px`,
		height: `${e.height * Wu}px`,
		overflow: "hidden"
	};
}
function qu(e) {
	let t = () => e.ctrl.type.toLowerCase().includes("dw") || e.ctrl.name.startsWith("dw_");
	return (() => {
		var n = zu(), r = n.firstChild;
		return J(n, "click", e.onClick, !0), X(r, () => e.ctrl.name), X(n, R(H, {
			get when() {
				return t();
			},
			get children() {
				var t = Lu(), n = t.firstChild.nextSibling;
				return n.nextSibling, X(t, () => e.ctrl.dataobject ?? e.ctrl.properties?.dataobject ?? "DataWindow", n), t;
			}
		}), null), X(n, R(H, {
			get when() {
				return U(() => !!e.ctrl.text)() && !t();
			},
			get children() {
				var t = Ru();
				return X(t, () => e.ctrl.text), t;
			}
		}), null), N((r) => {
			var i = {
				...Ku(e.ctrl),
				background: t() ? "var(--surface)" : "var(--surface-raised)"
			}, a = `${e.ctrl.name} (${e.ctrl.type})`;
			return r.e = ct(n, i, r.e), a !== r.t && K(n, "title", r.t = a), r;
		}, {
			e: void 0,
			t: void 0
		}), n;
	})();
}
function Ju(e) {
	let t = () => Object.entries(e.variables);
	return R(H, {
		get when() {
			return t().length > 0;
		},
		get children() {
			var e = Bu(), n = e.firstChild.nextSibling.firstChild;
			return X(n, R(V, {
				get each() {
					return t();
				},
				children: ([e, t]) => (() => {
					var n = Vu(), r = n.firstChild, i = r.nextSibling;
					return X(r, e), X(i, () => String(t)), n;
				})()
			})), e;
		}
	});
}
function Yu(e) {
	let t = e.store.getState(), [n, r] = j(null);
	P(() => {
		if (n() === e.objectName) return;
		let i = t().objects.astData;
		!i || "error" in i || (r(e.objectName), e.store.dispatch({
			tag: "runtime",
			windowId: e.windowId,
			action: {
				tag: "set-ast",
				ast: i
			}
		}), e.store.dispatch({
			tag: "runtime",
			windowId: e.windowId,
			action: {
				tag: "run-event",
				owner: e.objectName,
				event: "open"
			}
		}));
	});
	let i = () => t().objects.layout, a = () => t().runtimes[e.windowId] ?? lr, o = () => a().controlValues, s = () => nr(a().varEnv), c = (t) => {
		e.store.dispatch({
			tag: "runtime",
			windowId: e.windowId,
			action: {
				tag: "control-click",
				controlName: t.name
			}
		});
	};
	return (() => {
		var e = Uu();
		return X(e, R(H, {
			get when() {
				return !t().objects.astData;
			},
			get children() {
				return Hu();
			}
		}), null), X(e, R(H, {
			get when() {
				return i();
			},
			children: (e) => [R(Fu, {
				get naturalWidth() {
					return e().width;
				},
				get naturalHeight() {
					return e().height;
				},
				baseScale: Wu,
				get children() {
					return R(V, {
						get each() {
							return e().controls;
						},
						children: (t) => {
							if (t.type.toLowerCase().includes("datawindow") || t.name === "dw" || t.name.startsWith("dw_")) {
								let n = t.height > 0 ? t.height : e().height - t.y, r = {
									...Ku(t),
									height: `${n * Wu}px`
								};
								return (() => {
									var e = Iu();
									return X(e, R(H, {
										get when() {
											return o()[t.name];
										},
										get fallback() {
											return R(qu, {
												ctrl: t,
												onClick: () => c(t)
											});
										},
										children: (e) => R(Nu, { get data() {
											return e();
										} })
									})), N((t) => ct(e, r, t)), e;
								})();
							}
							return Gu(t, () => c(t));
						}
					});
				}
			}), R(Ju, { get variables() {
				return s();
			} })]
		}), null), e;
	})();
}
G(["click"]);
//#endregion
//#region src/features/objects/ObjectDetail.tsx
var Xu = /*#__PURE__*/ W("<div class=error-banner>Failed to load taint paths: "), Zu = /*#__PURE__*/ W("<button class=\"filter-pill active\"style=\"font-size:12px;padding:3px 10px;margin-bottom:8px\">Taint Explorer ↗"), Qu = /*#__PURE__*/ W("<table class=data-table style=font-size:12px><thead><tr><th>Severity</th><th>Category</th><th>Source</th><th>Sink</th><th></th></tr></thead><tbody>"), $u = /*#__PURE__*/ W("<div style=font-size:12px;color:var(--text-muted);margin-top:6px>Showing 10 of <!> paths."), ed = /*#__PURE__*/ W("<div style=\"padding:8px 0;color:var(--text-muted);font-size:13px\">No taint paths found through this object."), td = /*#__PURE__*/ W("<tr class=clickable><td><span></span></td><td></td><td style=font-size:11px>.</td><td style=font-size:11px>.</td><td><span class=trace-nav-link>View "), nd = /*#__PURE__*/ W("<div class=error-banner>Failed to load callers: "), rd = /*#__PURE__*/ W("<div class=error-banner>Failed to load callees: "), id = /*#__PURE__*/ W("<div style=\"padding:8px 0;color:var(--text-muted);font-size:13px\">No taint paths found through this procedure."), ad = /*#__PURE__*/ W("<div style=font-size:12px;color:var(--text-muted);margin-top:2px>extends "), od = /*#__PURE__*/ W("<div tabindex=-1><div class=detail-body>"), sd = /*#__PURE__*/ W("<p class=muted-note>No source file available."), cd = /*#__PURE__*/ W("<div style=height:420px;display:flex;flex-direction:column>"), ld = /*#__PURE__*/ W("<div class=card><p style=color:var(--red)>Error: "), ud = {
	critical: 0,
	high: 1,
	medium: 2,
	low: 3
};
function dd(e) {
	let [t] = re(() => e.objectName, async (e) => {
		let t = new URLSearchParams({
			object_name: e,
			limit: "10"
		}), n = await fetch("/api/analysis/taint-paths?" + t.toString());
		if (!n.ok) throw Error(`HTTP ${n.status}`);
		return n.json();
	}), n = () => [...t()?.paths ?? []].sort((e, t) => (ud[e.severity] ?? 9) - (ud[t.severity] ?? 9));
	function r(t) {
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "taintPathView",
					pathId: t
				}
			}
		});
	}
	return [
		R(H, {
			get when() {
				return t.loading;
			},
			get children() {
				return R(os, {});
			}
		}),
		R(H, {
			get when() {
				return t.error;
			},
			get children() {
				var e = Xu();
				return e.firstChild, X(e, () => String(t.error), null), e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !t.loading && !t.error)() && t();
			},
			get children() {
				return R(H, {
					get when() {
						return n().length > 0;
					},
					get fallback() {
						return ed();
					},
					get children() {
						return [
							R(H, {
								get when() {
									return (t()?.total ?? 0) > 0;
								},
								get children() {
									var t = Zu();
									return t.$$click = () => e.store.dispatch({
										tag: "nav",
										action: {
											tag: "navigate",
											route: { view: "taintExplorer" }
										}
									}), t;
								}
							}),
							(() => {
								var e = Qu(), t = e.firstChild.nextSibling;
								return X(t, R(V, {
									get each() {
										return n();
									},
									children: (e) => (() => {
										var t = td(), n = t.firstChild, i = n.firstChild, a = n.nextSibling, o = a.nextSibling, s = o.firstChild, c = o.nextSibling, l = c.firstChild, u = c.nextSibling.firstChild;
										return u.firstChild, t.$$click = () => r(e.id), X(i, () => e.severity), X(a, () => e.category), X(o, () => e.source.object, s), X(o, () => e.source.proc, null), X(c, () => e.sink.object, l), X(c, () => e.sink.proc, null), X(u, R(fi, {
											size: 12,
											style: { "vertical-align": "middle" }
										}), null), N(() => q(i, `badge badge-severity-${e.severity}`)), t;
									})()
								})), e;
							})(),
							R(H, {
								get when() {
									return (t()?.total ?? 0) > 10;
								},
								get children() {
									var e = $u(), n = e.firstChild.nextSibling;
									return n.nextSibling, X(e, () => t().total, n), e;
								}
							})
						];
					}
				});
			}
		})
	];
}
function fd(e) {
	let [t] = re(() => `${e.procObject}::${e.procName}`, async () => {
		let t = await fetch(`/api/procedures/${encodeURIComponent(e.procObject)}/${encodeURIComponent(e.procName)}`);
		if (!t.ok) throw Error(`HTTP ${t.status}`);
		return t.json();
	});
	return [
		R(H, {
			get when() {
				return t.loading;
			},
			get children() {
				return R(os, {});
			}
		}),
		R(H, {
			get when() {
				return t.error;
			},
			get children() {
				var e = nd();
				return e.firstChild, X(e, () => String(t.error), null), e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !t.loading && !t.error)() && t();
			},
			get children() {
				return R(Nc, {
					title: "",
					get items() {
						return (t()?.callers ?? []).map((t) => ({
							type: "procedure",
							name: t.proc,
							context: t.object,
							tooltip: `${t.object}.${t.proc}`,
							onClick: () => e.store.dispatch({
								tag: "objects",
								action: {
									tag: "proc-select",
									objectName: t.object,
									procName: t.proc
								}
							})
						}));
					},
					emptyText: "No callers found."
				});
			}
		})
	];
}
function pd(e) {
	let [t] = re(() => `${e.procObject}::${e.procName}`, async () => {
		let t = await fetch(`/api/procedures/${encodeURIComponent(e.procObject)}/${encodeURIComponent(e.procName)}`);
		if (!t.ok) throw Error(`HTTP ${t.status}`);
		return t.json();
	});
	return [
		R(H, {
			get when() {
				return t.loading;
			},
			get children() {
				return R(os, {});
			}
		}),
		R(H, {
			get when() {
				return t.error;
			},
			get children() {
				var e = rd();
				return e.firstChild, X(e, () => String(t.error), null), e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !t.loading && !t.error)() && t();
			},
			get children() {
				return R(Nc, {
					title: "",
					get items() {
						return (t()?.callees ?? []).map((t) => {
							let n = t.indexOf("."), r = n > 0 ? t.slice(0, n) : e.procObject, i = n > 0 ? t.slice(n + 1) : t;
							return {
								type: "procedure",
								name: i,
								context: r,
								onClick: () => e.store.dispatch({
									tag: "objects",
									action: {
										tag: "proc-select",
										objectName: r,
										procName: i
									}
								})
							};
						});
					},
					emptyText: "No callees found."
				});
			}
		})
	];
}
function md(e) {
	let [t] = re(() => `${e.procObject}::${e.procName}`, async () => {
		let t = new URLSearchParams({
			object_name: e.procObject,
			proc_name: e.procName,
			limit: "10"
		}), n = await fetch("/api/analysis/taint-paths?" + t.toString());
		if (!n.ok) throw Error(`HTTP ${n.status}`);
		return n.json();
	}), n = () => [...t()?.paths ?? []].sort((e, t) => (ud[e.severity] ?? 9) - (ud[t.severity] ?? 9));
	return [
		R(H, {
			get when() {
				return t.loading;
			},
			get children() {
				return R(os, {});
			}
		}),
		R(H, {
			get when() {
				return t.error;
			},
			get children() {
				var e = Xu();
				return e.firstChild, X(e, () => String(t.error), null), e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !t.loading && !t.error)() && t();
			},
			get children() {
				return R(H, {
					get when() {
						return n().length > 0;
					},
					get fallback() {
						return id();
					},
					get children() {
						var t = Qu(), r = t.firstChild.nextSibling;
						return X(r, R(V, {
							get each() {
								return n();
							},
							children: (t) => (() => {
								var n = td(), r = n.firstChild, i = r.firstChild, a = r.nextSibling, o = a.nextSibling, s = o.firstChild, c = o.nextSibling, l = c.firstChild, u = c.nextSibling.firstChild;
								return u.firstChild, n.$$click = () => e.store.dispatch({
									tag: "nav",
									action: {
										tag: "navigate",
										route: {
											view: "taintPathView",
											pathId: t.id
										}
									}
								}), X(i, () => t.severity), X(a, () => t.category), X(o, () => t.source.object, s), X(o, () => t.source.proc, null), X(c, () => t.sink.object, l), X(c, () => t.sink.proc, null), X(u, R(fi, {
									size: 12,
									style: { "vertical-align": "middle" }
								}), null), N(() => q(i, `badge badge-severity-${t.severity}`)), n;
							})()
						})), t;
					}
				});
			}
		})
	];
}
function hd(e) {
	let t = e.o, n = e.store, r = n.getState(), i = () => r().objects.sourceDetail, a = () => r().objects.selectedProcName ?? void 0, o = t.kind === "powerscript" ? "badge-ps" : t.kind === "datawindow" ? "badge-dw" : "badge-proj", [s, c] = j(!1), [l, u] = j(!1), [d, f] = j(!1), [p, m] = j(!1), [h, g] = j(!1), [_, v] = j(!1), [y, b] = j(null), [x, ee] = j(null), [S, C] = j(null), [w, T] = j(null), E = () => t.callers?.length ?? 0, D = () => t.dws_used?.length ?? 0, O = () => t.tables_accessed?.length ?? 0, k = () => t.metrics != null, te = () => [
		{
			label: "Callers",
			count: E(),
			active: s(),
			onClick: () => c((e) => !e)
		},
		...D() > 0 ? [{
			label: "DWs",
			count: D(),
			active: l(),
			onClick: () => u((e) => !e)
		}] : [],
		...O() > 0 ? [{
			label: "Tables",
			count: O(),
			active: d(),
			onClick: () => f((e) => !e)
		}] : [],
		...k() ? [{
			label: "Metrics",
			active: p(),
			onClick: () => m((e) => !e)
		}] : [],
		{
			label: "Taint",
			active: h(),
			onClick: () => g((e) => !e)
		},
		...t.kind === "powerscript" ? [{
			label: "Preview",
			active: _(),
			onClick: () => v((e) => !e)
		}] : []
	], A = () => {
		if ((t.ancestors?.length ?? 0) !== 0) return (() => {
			var e = ad();
			return e.firstChild, X(e, () => t.ancestors[0], null), e;
		})();
	};
	function M() {
		c(!1), u(!1), f(!1), m(!1), g(!1), v(!1), b(null), ee(null), C(null), T(null);
	}
	let N = {
		onFindCallers: (e, t) => b((n) => n?.procName === e && n.procObject === t ? null : {
			procName: e,
			procObject: t
		}),
		onFindCallees: (e, t) => ee((n) => n?.procName === e && n.procObject === t ? null : {
			procName: e,
			procObject: t
		}),
		onViewCfg: (e, t) => C((n) => n?.procName === e && n.procObject === t ? null : {
			procName: e,
			procObject: t
		}),
		onViewTaint: (e, t) => T((n) => n?.procName === e && n.procObject === t ? null : {
			procName: e,
			procObject: t
		})
	};
	return (() => {
		var e = od(), r = e.firstChild;
		return e.$$keydown = (e) => {
			e.key === "Escape" && M();
		}, X(e, R(Tc, {
			get name() {
				return t.name;
			},
			badgeClass: o,
			get badgeLabel() {
				return t.kind;
			},
			get subtitle() {
				return A();
			}
		}), r), X(e, R(Gl, { get items() {
			return te();
		} }), r), X(r, R(H, {
			get when() {
				return t.file;
			},
			get fallback() {
				return sd();
			},
			get children() {
				return R(Vl, {
					store: n,
					get file() {
						return t.file;
					},
					get objectName() {
						return t.name;
					},
					get sourceDetail() {
						return i();
					},
					get selectedProcName() {
						return a();
					},
					contextActions: N
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return (t.procedures?.length ?? 0) > 0;
			},
			get children() {
				return R(Uc, {
					store: n,
					get objectName() {
						return t.name;
					},
					get procedures() {
						return t.procedures;
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return s();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Callers (${E()})`;
					},
					onClose: () => c(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.callers ?? []).map((e) => ({
									type: "object",
									name: e,
									onClick: () => n.dispatch({
										tag: "objects",
										action: {
											tag: "select",
											name: e
										}
									})
								}));
							},
							emptyText: "No callers found."
						});
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return l();
			},
			get children() {
				return R(ql, {
					get title() {
						return `DataWindows Used (${D()})`;
					},
					onClose: () => u(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.dws_used ?? []).map((e) => ({
									type: "datawindow",
									name: e,
									onClick: () => n.dispatch({
										tag: "datawindows",
										action: {
											tag: "select",
											name: e
										}
									})
								}));
							}
						});
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return d();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Tables Accessed (${O()})`;
					},
					onClose: () => f(!1),
					get children() {
						return R(Nc, {
							title: "",
							meta: "based on all DataWindows and direct SQL",
							get items() {
								return (t.tables_accessed ?? []).map((e) => ({
									type: "table",
									name: e,
									onClick: () => n.dispatch({
										tag: "tables",
										action: {
											tag: "select",
											name: e
										}
									})
								}));
							}
						});
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return U(() => !!p())() && t.metrics;
			},
			get children() {
				return R(ql, {
					title: "Metrics",
					onClose: () => m(!1),
					get children() {
						return R(Ic, { get metrics() {
							return t.metrics;
						} });
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return h();
			},
			get children() {
				return R(ql, {
					title: "Taint Paths",
					onClose: () => g(!1),
					get children() {
						return R(dd, {
							get objectName() {
								return t.name;
							},
							store: n
						});
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return _();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Preview: ${t.name}`;
					},
					onClose: () => v(!1),
					get children() {
						return R(Yu, {
							get objectName() {
								return t.name;
							},
							get windowId() {
								return `preview-${t.name}`;
							},
							store: n
						});
					}
				});
			}
		}), null), X(r, R(H, {
			get when() {
				return y();
			},
			children: (e) => R(ql, {
				get title() {
					return `Callers of ${e().procName}`;
				},
				onClose: () => b(null),
				get children() {
					return R(fd, {
						get procName() {
							return e().procName;
						},
						get procObject() {
							return e().procObject;
						},
						store: n
					});
				}
			})
		}), null), X(r, R(H, {
			get when() {
				return x();
			},
			children: (e) => R(ql, {
				get title() {
					return `Callees of ${e().procName}`;
				},
				onClose: () => ee(null),
				get children() {
					return R(pd, {
						get procName() {
							return e().procName;
						},
						get procObject() {
							return e().procObject;
						},
						store: n
					});
				}
			})
		}), null), X(r, R(H, {
			get when() {
				return S();
			},
			children: (e) => R(ql, {
				get title() {
					return `CFG: ${e().procName}`;
				},
				onClose: () => C(null),
				get children() {
					var t = cd();
					return X(t, R(_u, {
						get object() {
							return e().procObject;
						},
						get proc() {
							return e().procName;
						},
						store: n,
						onGoto: () => n.dispatch({
							tag: "nav",
							action: {
								tag: "navigate",
								route: {
									view: "cfgDiagram",
									object: e().procObject,
									proc: e().procName
								}
							}
						}),
						gotoLabel: "Full CFG"
					})), t;
				}
			})
		}), null), X(r, R(H, {
			get when() {
				return w();
			},
			children: (e) => R(ql, {
				get title() {
					return `Taint: ${e().procName}`;
				},
				onClose: () => T(null),
				get children() {
					return R(md, {
						get procName() {
							return e().procName;
						},
						get procObject() {
							return e().procObject;
						},
						store: n
					});
				}
			})
		}), null), e;
	})();
}
function gd(e) {
	let t = e.store, n = t.getState(), r = () => n().objects.detail;
	return [R(Dc, {
		label: "Objects",
		onClick: () => t.dispatch({
			tag: "objects",
			action: { tag: "back-to-objects" }
		})
	}), R(H, {
		get when() {
			return r();
		},
		get fallback() {
			return R(os, {});
		},
		children: (e) => "error" in e() ? (() => {
			var t = ld(), n = t.firstChild;
			return n.firstChild, X(n, () => e().error, null), t;
		})() : R(hd, {
			get o() {
				return e();
			},
			obj: r,
			store: t
		})
	})];
}
G(["click", "keydown"]);
//#endregion
//#region src/features/objects/Objects.tsx
function _d(e) {
	let t = e.store, n = t.getState(), r = () => n().objects;
	return ae(() => {
		t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: { view: "objects" }
			}
		}), t.dispatch({
			tag: "objects",
			action: {
				tag: "search",
				q: r().q
			}
		});
	}), R(H, {
		get when() {
			return r().detail;
		},
		get fallback() {
			return R(Cc, { store: t });
		},
		get children() {
			return R(gd, { store: t });
		}
	});
}
//#endregion
//#region src/components/detail/CodeBlock.tsx
var vd = /*#__PURE__*/ W("<pre class=\"code-viewer sql-code\">"), yd = /*#__PURE__*/ W("<div class=source-viewer><div class=source-gutter></div><div class=source-code-area><pre>"), bd = /*#__PURE__*/ W("<div class=source-gutter-line>"), xd = /*#__PURE__*/ W("<span class=source-code-line>");
function Sd(e) {
	return (() => {
		var t = vd();
		return N((n) => {
			var r = e.style, i = rl(e.code);
			return n.e = ct(t, r, n.e), i !== n.t && (t.innerHTML = n.t = i), n;
		}, {
			e: void 0,
			t: void 0
		}), t;
	})();
}
function Cd(e) {
	let t = () => $c(e.code).split("\n"), n = () => e.baseLine ?? 1, r = (t) => n() + t === e.highlightLine;
	return (() => {
		var i = yd(), a = i.firstChild, o = a.nextSibling.firstChild;
		return X(a, R(V, {
			get each() {
				return t();
			},
			children: (t, i) => (() => {
				var t = bd();
				return t.$$click = () => e.onLineClick?.(n() + i()), X(t, () => String(n() + i())), N((n) => {
					var a = !!r(i()), o = e.onLineClick != null;
					return a !== n.e && t.classList.toggle("source-gutter-line--error", n.e = a), o !== n.t && t.classList.toggle("source-gutter-line--clickable", n.t = o), n;
				}, {
					e: void 0,
					t: void 0
				}), t;
			})()
		})), X(o, R(V, {
			get each() {
				return t();
			},
			children: (e, n) => [(() => {
				var t = xd();
				return t.innerHTML = e, N(() => t.classList.toggle("source-code-line--error", !!r(n()))), t;
			})(), U(() => n() < t().length - 1 ? "\n" : "")]
		})), i;
	})();
}
G(["click"]);
//#endregion
//#region src/components/detail/SqlStatementCard.tsx
var wd = /*#__PURE__*/ W("<span class=\"badge badge-warn\">&#x26A0; unparsed"), Td = /*#__PURE__*/ W("<div class=sql-tables-row><span class=sql-tables-label>Tables:"), Ed = /*#__PURE__*/ W("<div class=sql-stmt-block><div class=sql-stmt-header><span>");
function Dd(e) {
	switch (e.toUpperCase()) {
		case "SELECT": return "badge badge-ps";
		case "INSERT": return "badge badge-dw";
		case "UPDATE": return "badge badge-sub";
		case "DELETE": return "badge badge-cc";
		default: return "badge badge-proj";
	}
}
function Od(e) {
	return (() => {
		var t = Ed(), n = t.firstChild, r = n.firstChild;
		return X(r, () => e.stmt.operation), X(n, R(H, {
			get when() {
				return !e.stmt.parse_ok;
			},
			get children() {
				return wd();
			}
		}), null), X(t, R(Sd, { get code() {
			return e.stmt.formatted_sql;
		} }), null), X(t, R(H, {
			get when() {
				return U(() => !!e.stmt.tables)() && e.stmt.tables.length > 0;
			},
			get children() {
				var t = Td();
				return t.firstChild, X(t, R(V, {
					get each() {
						return e.stmt.tables;
					},
					children: (t) => R(is, {
						name: t,
						get store() {
							return e.store;
						},
						size: "sm"
					})
				}), null), t;
			}
		}), null), N(() => q(r, Dd(e.stmt.operation))), t;
	})();
}
//#endregion
//#region src/features/objects/ProcedureDetail.tsx
var kd = /*#__PURE__*/ W("<button class=\"filter-pill active\"style=\"font-size:12px;padding:3px 10px;margin-bottom:8px\">Taint Explorer ↗"), Ad = /*#__PURE__*/ W("<div class=error-banner>Failed to load taint paths: "), jd = /*#__PURE__*/ W("<table class=data-table style=font-size:12px><thead><tr><th>Severity</th><th>Category</th><th>Source</th><th>Sink</th><th></th></tr></thead><tbody>"), Md = /*#__PURE__*/ W("<div style=font-size:12px;color:var(--text-muted);margin-top:6px>Showing 10 of <!> paths."), Nd = /*#__PURE__*/ W("<div style=\"padding:8px 0;color:var(--text-muted);font-size:13px\">No taint paths found through this procedure."), Pd = /*#__PURE__*/ W("<tr class=clickable><td><span></span></td><td></td><td style=font-size:11px>.</td><td style=font-size:11px>.</td><td><span class=trace-nav-link>View "), Fd = /*#__PURE__*/ W("<div style=font-size:12px;color:var(--text-muted)>"), Id = /*#__PURE__*/ W("<span> "), Ld = /*#__PURE__*/ W("<span>(<!>) "), Rd = /*#__PURE__*/ W("<span>returns <!> "), zd = /*#__PURE__*/ W("<div style=font-size:11px;color:var(--text-muted);margin-top:8px>:<!>–"), Bd = /*#__PURE__*/ W("<div class=sql-tab-body>"), Vd = /*#__PURE__*/ W("<div style=height:420px;display:flex;flex-direction:column>"), Hd = /*#__PURE__*/ W("<div><div class=detail-body>"), Ud = /*#__PURE__*/ W("<span style=color:var(--accent)>"), Wd = /*#__PURE__*/ W("<div class=card><p style=color:var(--red)>Error: "), Gd = {
	critical: 0,
	high: 1,
	medium: 2,
	low: 3
};
function Kd(e) {
	let [t] = re(() => `${e.objectName}::${e.procName}`, async () => {
		let t = new URLSearchParams({
			object_name: e.objectName,
			proc_name: e.procName,
			limit: "10"
		}), n = await fetch("/api/analysis/taint-paths?" + t.toString());
		if (!n.ok) throw Error(`HTTP ${n.status}`);
		return n.json();
	}), n = () => [...t()?.paths ?? []].sort((e, t) => (Gd[e.severity] ?? 9) - (Gd[t.severity] ?? 9));
	function r(t) {
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "taintPathView",
					pathId: t
				}
			}
		});
	}
	return [
		R(H, {
			get when() {
				return (t()?.total ?? 0) > 0;
			},
			get children() {
				var t = kd();
				return t.$$click = () => e.store.dispatch({
					tag: "nav",
					action: {
						tag: "navigate",
						route: { view: "taintExplorer" }
					}
				}), t;
			}
		}),
		R(H, {
			get when() {
				return t.loading;
			},
			get children() {
				return R(os, {});
			}
		}),
		R(H, {
			get when() {
				return t.error;
			},
			get children() {
				var e = Ad();
				return e.firstChild, X(e, () => String(t.error), null), e;
			}
		}),
		R(H, {
			get when() {
				return U(() => !t.loading && !t.error)() && t();
			},
			get children() {
				return R(H, {
					get when() {
						return n().length > 0;
					},
					get fallback() {
						return Nd();
					},
					get children() {
						return [(() => {
							var e = jd(), t = e.firstChild.nextSibling;
							return X(t, R(V, {
								get each() {
									return n();
								},
								children: (e) => (() => {
									var t = Pd(), n = t.firstChild, i = n.firstChild, a = n.nextSibling, o = a.nextSibling, s = o.firstChild, c = o.nextSibling, l = c.firstChild, u = c.nextSibling.firstChild;
									return u.firstChild, t.$$click = () => r(e.id), X(i, () => e.severity), X(a, () => e.category), X(o, () => e.source.object, s), X(o, () => e.source.proc, null), X(c, () => e.sink.object, l), X(c, () => e.sink.proc, null), X(u, R(fi, {
										size: 12,
										style: { "vertical-align": "middle" }
									}), null), N(() => q(i, `badge badge-severity-${e.severity}`)), t;
								})()
							})), e;
						})(), R(H, {
							get when() {
								return (t()?.total ?? 0) > 10;
							},
							get children() {
								var e = Md(), n = e.firstChild.nextSibling;
								return n.nextSibling, X(e, () => t().total, n), e;
							}
						})];
					}
				});
			}
		})
	];
}
function qd(e) {
	let { p: t, store: n } = e, r = Ra(t.proc_type), [i, a] = j(!1), [o, s] = j(!1), [c, l] = j(!1), [u, d] = j(!1), [f, p] = j(!1), m = () => t.callers?.length ?? 0, h = () => t.callees?.length ?? 0, g = () => t.sql_statements?.length ?? 0, _ = () => [
		{
			label: "Callers",
			count: m(),
			active: i(),
			onClick: () => a((e) => !e)
		},
		{
			label: "Callees",
			count: h(),
			active: o(),
			onClick: () => s((e) => !e)
		},
		...g() > 0 ? [{
			label: "SQL",
			count: g(),
			active: c(),
			onClick: () => l((e) => !e)
		}] : [],
		...t.cyclomatic == null ? [] : [{ label: `CC: ${t.cyclomatic}` }],
		{
			label: "Taint",
			active: u(),
			onClick: () => d((e) => !e)
		},
		{
			label: "CFG",
			active: f(),
			onClick: () => p((e) => !e)
		}
	];
	function v(e) {
		e.key === "Escape" && (a(!1), s(!1), l(!1), d(!1), p(!1));
	}
	let y = (() => {
		var e = Fd();
		return X(e, (() => {
			var e = U(() => !!t.modifiers);
			return () => e() && (() => {
				var e = Id(), n = e.firstChild;
				return X(e, () => t.modifiers, n), e;
			})();
		})(), null), X(e, (() => {
			var e = U(() => !!t.params);
			return () => e() && (() => {
				var e = Ld(), n = e.firstChild.nextSibling;
				return n.nextSibling, X(e, () => t.params, n), e;
			})();
		})(), null), X(e, (() => {
			var e = U(() => !!t.return_type);
			return () => e() && (() => {
				var e = Rd(), n = e.firstChild.nextSibling;
				return n.nextSibling, X(e, () => t.return_type, n), e;
			})();
		})(), null), e;
	})();
	return (() => {
		var b = Hd(), x = b.firstChild;
		return b.$$keydown = v, X(b, R(Tc, {
			get name() {
				return `${t.object}.`;
			},
			badgeClass: `badge-${r}`,
			get badgeLabel() {
				return t.proc_type;
			},
			get subtitle() {
				return [
					(() => {
						var e = Ud();
						return X(e, () => t.name), e;
					})(),
					" ",
					y
				];
			}
		}), x), X(b, R(Gl, { get items() {
			return _();
		} }), x), X(x, R(H, {
			get when() {
				return t.source_original;
			},
			get children() {
				return [R(Cd, {
					get code() {
						return t.source_original;
					},
					get baseLine() {
						return t.start_line ?? 1;
					},
					onLineClick: (r) => n.dispatch({
						tag: "objects",
						action: {
							tag: "go-slice",
							object: e.objectName,
							proc: t.name,
							line: r,
							direction: "backward"
						}
					})
				}), R(H, {
					get when() {
						return t.file;
					},
					get children() {
						var e = zd(), n = e.firstChild, r = n.nextSibling;
						return r.nextSibling, X(e, () => t.file, n), X(e, () => t.start_line ?? "", r), X(e, () => t.end_line ?? "", null), e;
					}
				})];
			}
		}), null), X(x, R(H, {
			get when() {
				return i();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Callers (${m()})`;
					},
					onClose: () => a(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.callers ?? []).map((e) => ({
									type: "procedure",
									name: e.proc,
									context: e.object,
									tooltip: `${e.object}.${e.proc}`,
									onClick: () => n.dispatch({
										tag: "objects",
										action: {
											tag: "proc-select",
											objectName: e.object,
											procName: e.proc
										}
									})
								}));
							},
							emptyText: "No callers found."
						});
					}
				});
			}
		}), null), X(x, R(H, {
			get when() {
				return o();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Callees (${h()})`;
					},
					onClose: () => s(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.callees ?? []).map((e) => ({
									type: "procedure",
									name: e,
									onClick: () => {
										let r = e.indexOf(".");
										r > 0 ? n.dispatch({
											tag: "objects",
											action: {
												tag: "proc-select",
												objectName: e.slice(0, r),
												procName: e.slice(r + 1)
											}
										}) : n.dispatch({
											tag: "objects",
											action: {
												tag: "proc-select",
												objectName: t.object,
												procName: e
											}
										});
									}
								}));
							},
							emptyText: "No callees found."
						});
					}
				});
			}
		}), null), X(x, R(H, {
			get when() {
				return U(() => !!c())() && g() > 0;
			},
			get children() {
				return R(ql, {
					get title() {
						return `SQL Statements (${g()})`;
					},
					onClose: () => l(!1),
					get children() {
						var e = Bd();
						return X(e, R(V, {
							get each() {
								return t.sql_statements;
							},
							children: (e) => R(Od, {
								stmt: e,
								store: n
							})
						})), e;
					}
				});
			}
		}), null), X(x, R(H, {
			get when() {
				return u();
			},
			get children() {
				return R(ql, {
					title: "Taint Paths",
					onClose: () => d(!1),
					get children() {
						return R(Kd, {
							get objectName() {
								return e.objectName;
							},
							get procName() {
								return t.name;
							},
							store: n
						});
					}
				});
			}
		}), null), X(x, R(H, {
			get when() {
				return f();
			},
			get children() {
				return R(ql, {
					title: "Control Flow Graph",
					onClose: () => p(!1),
					get children() {
						var e = Vd();
						return X(e, R(_u, {
							get object() {
								return t.object;
							},
							get proc() {
								return t.name;
							},
							store: n,
							onGoto: () => n.dispatch({
								tag: "nav",
								action: {
									tag: "navigate",
									route: {
										view: "cfgDiagram",
										object: t.object,
										proc: t.name
									}
								}
							}),
							gotoLabel: "Full CFG"
						})), e;
					}
				});
			}
		}), null), b;
	})();
}
function Jd(e) {
	let t = e.store, n = t.getState(), r = () => n().objects.procedureDetail, i = () => {
		let e = n().nav.route;
		return e.view === "procedureDetail" ? e.name : "";
	};
	return [R(Dc, {
		get label() {
			return i();
		},
		onClick: () => t.dispatch({
			tag: "objects",
			action: {
				tag: "select",
				name: i()
			}
		})
	}), R(H, {
		get when() {
			return r();
		},
		get fallback() {
			return R(os, {});
		},
		children: (e) => "error" in e() ? (() => {
			var t = Wd(), n = t.firstChild;
			return n.firstChild, X(n, () => e().error, null), t;
		})() : R(qd, {
			p: e(),
			store: t,
			get objectName() {
				return i();
			}
		})
	})];
}
G(["click", "keydown"]);
//#endregion
//#region src/features/objects/ProceduresList.tsx
var Yd = /*#__PURE__*/ W("<th style=cursor:pointer> "), Xd = /*#__PURE__*/ W("<div style=display:flex;gap:8px;align-items:center;margin-bottom:12px><input class=search-input type=text placeholder=\"Search procedures or objects…\"style=flex:1>"), Zd = /*#__PURE__*/ W("<div class=filter-pills style=margin-bottom:12px>"), Qd = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=\"data-table procs-list-table\"><thead><tr><th>Type</th></tr></thead><tbody>"), $d = /*#__PURE__*/ W("<button>"), ef = /*#__PURE__*/ W("<tr><td colspan=5 style=color:var(--text-muted);padding:16px>No procedures found."), tf = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td style=\"padding:4px 8px\"></td><td><span></span></td><td></td><td style=font-size:12px;color:var(--text-muted)>"), nf = /*#__PURE__*/ W("<span class=\"badge badge-cc\">"), rf = {
	function: "function",
	subroutine: "subroutine",
	event: "event",
	on: "on"
};
function af(e, t, n) {
	let r = (e, r) => {
		let i, a;
		switch (t) {
			case "object":
				i = e.object, a = r.object;
				break;
			case "cyclomatic":
				i = e.cyclomatic ?? -1, a = r.cyclomatic ?? -1;
				break;
			case "caller_count":
				i = e.caller_count, a = r.caller_count;
				break;
			default: i = e.name, a = r.name;
		}
		return i < a ? n === "asc" ? -1 : 1 : i > a ? n === "asc" ? 1 : -1 : 0;
	};
	return [...e].sort(r);
}
function of(e) {
	let t = e.store, n = t.getState(), r = () => n().objects;
	ae(() => {
		t.dispatch({
			tag: "objects",
			action: { tag: "procs-list-load" }
		});
	}), _c({
		items: () => i().map((e) => ({ select: () => t.dispatch({
			tag: "objects",
			action: {
				tag: "proc-select",
				objectName: e.object,
				procName: e.name
			}
		}) })),
		tableSelector: ".procs-list-table"
	});
	let i = () => {
		let e = r().proceduresList ?? [], t = r().proceduresListQ.toLowerCase(), n = r().proceduresListKind;
		return af(e.filter((e) => !(n && e.proc_type !== n || t && !e.name.toLowerCase().includes(t) && !e.object.toLowerCase().includes(t))), r().proceduresListSort, r().proceduresListOrder);
	}, a = (e, n) => {
		let i = () => r().proceduresListSort === e, a = () => i() ? r().proceduresListOrder === "asc" ? R(Ei, {
			size: 11,
			style: { "vertical-align": "middle" }
		}) : R(bi, {
			size: 11,
			style: { "vertical-align": "middle" }
		}) : R(mi, {
			size: 11,
			style: {
				"vertical-align": "middle",
				opacity: "0.3"
			}
		});
		return (() => {
			var r = Yd(), o = r.firstChild;
			return r.$$click = () => t.dispatch({
				tag: "objects",
				action: {
					tag: "procs-list-sort",
					col: e
				}
			}), X(r, n, o), X(r, a, null), N(() => q(r, i() ? "sorted" : "")), r;
		})();
	}, o = () => r().proceduresList?.length ?? 0, s = () => i().length, c = () => r().proceduresListQ || r().proceduresListKind ? `Procedures — showing ${s()} of ${o()}` : `Procedures (${o()})`;
	return [
		(() => {
			var e = Xd(), n = e.firstChild;
			return n.$$input = (e) => {
				t.dispatch({
					tag: "objects",
					action: {
						tag: "procs-list-filter",
						q: e.currentTarget.value
					}
				});
			}, N(() => n.value = r().proceduresListQ), e;
		})(),
		(() => {
			var e = Zd();
			return X(e, R(V, {
				each: [
					"",
					"function",
					"subroutine",
					"event",
					"on"
				],
				children: (e) => (() => {
					var n = $d();
					return n.$$click = () => {
						t.dispatch({
							tag: "objects",
							action: {
								tag: "procs-list-filter-kind",
								kind: e
							}
						});
					}, X(n, () => e ? rf[e] ?? e : "All"), N(() => q(n, `filter-pill${r().proceduresListKind === e ? " active" : ""}`)), n;
				})()
			})), e;
		})(),
		R(H, {
			get when() {
				return !r().proceduresListLoading;
			},
			get fallback() {
				return R(os, {});
			},
			get children() {
				var e = Qd(), n = e.firstChild, r = n.firstChild, o = n.nextSibling.firstChild, s = o.firstChild, l = s.firstChild, u = o.nextSibling;
				return X(r, c), X(s, () => a("name", "Name"), l), X(s, () => a("object", "Object"), l), X(s, () => a("cyclomatic", "CC"), null), X(s, () => a("caller_count", "Callers"), null), X(u, R(V, {
					get each() {
						return i();
					},
					get fallback() {
						return (() => {
							var e = ef();
							return e.firstChild, e;
						})();
					},
					children: (e) => (() => {
						var n = tf(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.firstChild, s = a.nextSibling, c = s.nextSibling;
						return X(r, R(mc, {
							type: "procedure",
							get name() {
								return e.name;
							},
							get tooltip() {
								return `${e.object}.${e.name}`;
							},
							onClick: () => t.dispatch({
								tag: "objects",
								action: {
									tag: "proc-select",
									objectName: e.object,
									procName: e.name
								}
							})
						})), X(i, R(mc, {
							type: "object",
							get name() {
								return e.object;
							},
							onClick: () => t.dispatch({
								tag: "objects",
								action: {
									tag: "select",
									name: e.object
								}
							})
						})), X(o, () => e.proc_type), X(s, (() => {
							var t = U(() => e.cyclomatic != null);
							return () => t() ? (() => {
								var t = nf();
								return X(t, () => String(e.cyclomatic)), t;
							})() : "–";
						})()), X(c, () => String(e.caller_count)), N(() => q(o, `badge badge-${Ra(e.proc_type)}`)), n;
					})()
				})), e;
			}
		})
	];
}
G(["click", "input"]);
//#endregion
//#region src/features/datawindows/DWList.tsx
var sf = /*#__PURE__*/ W("<div class=search-bar><input class=search-input type=text placeholder=\"Search DataWindows…\">"), cf = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=\"data-table dw-list-table\"><thead><tr><th>Name</th><th>File</th></tr></thead><tbody>"), lf = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td style=font-size:11px;color:var(--text-muted)>");
function uf(e) {
	let t = e.store, n = t.getState(), r = () => n().datawindows;
	return ae(() => {
		r().items.length === 0 && t.dispatch({
			tag: "datawindows",
			action: {
				tag: "search",
				q: r().q
			}
		});
	}), _c({
		items: () => r().items.map((e) => ({ select: () => t.dispatch({
			tag: "datawindows",
			action: {
				tag: "select",
				name: e.name
			}
		}) })),
		tableSelector: ".dw-list-table"
	}), [(() => {
		var e = sf(), n = e.firstChild;
		return n.$$input = (e) => t.dispatch({
			tag: "datawindows",
			action: {
				tag: "search",
				q: e.currentTarget.value
			}
		}), N(() => n.value = r().q), e;
	})(), R(H, {
		get when() {
			return !r().loading || r().items.length > 0;
		},
		get fallback() {
			return R(os, {});
		},
		get children() {
			var e = cf(), n = e.firstChild, i = n.firstChild, a = n.nextSibling.firstChild.nextSibling;
			return X(i, (() => {
				var e = U(() => !!r().q);
				return () => e() ? `DataWindows — ${r().total} results` : `DataWindows (${r().total})`;
			})()), X(a, R(V, {
				get each() {
					return r().items;
				},
				children: (e) => (() => {
					var n = lf(), r = n.firstChild, i = r.nextSibling;
					return X(r, R(mc, {
						type: "datawindow",
						get name() {
							return e.name;
						},
						onClick: () => t.dispatch({
							tag: "datawindows",
							action: {
								tag: "select",
								name: e.name
							}
						})
					})), X(i, () => za(e.file)), n;
				})()
			})), e;
		}
	})];
}
G(["input"]);
//#endregion
//#region src/core/dwLayout.ts
var df = {
	BkHeader: 0,
	BkDetail: 1,
	BkSummary: 2,
	BkFooter: 3,
	BkBackground: 4,
	BkForeground: 5
};
function ff(e) {
	return e ? typeof e == "object" && "tag" in e ? e.tag : String(e) : "BkDetail";
}
function pf(e) {
	if (!e) return null;
	let t = e.indexOf("~t");
	return (t >= 0 ? e.slice(0, t).trim() : e.trim()) || null;
}
function mf(e) {
	let t = [...e.bands].sort((e, t) => (df[ff(e.kind)] ?? 99) - (df[ff(t.kind)] ?? 99)), n = [], r = 0;
	for (let e of t) {
		let t = e.height ?? 0;
		n.push({
			tag: ff(e.kind),
			height: t,
			yOffset: r
		}), r += t;
	}
	let i = e.controls.filter((e) => e.x != null && e.y != null).map((e) => ({
		type: e.type,
		name: e.name,
		band: ff(e.band),
		x: e.x ?? 0,
		y: e.y ?? 0,
		width: e.width ?? 0,
		height: e.height ?? 0,
		label: e.type === "text" ? pf(e.attrs.text) : null,
		colName: e.type === "column" ? e.name : null
	}));
	return {
		totalWidth: i.length > 0 ? Math.max(...i.map((e) => e.x + e.width)) : 0,
		totalHeight: r,
		bands: n,
		controls: i
	};
}
//#endregion
//#region src/components/DwPreview.tsx
var hf = /*#__PURE__*/ W("<div style=\"position:absolute;left:0;border-bottom:1px solid #ddd;box-sizing:border-box\"><span style=\"font-size:9px;color:#888;padding:1px 3px;line-height:1\">"), gf = /*#__PURE__*/ W("<div style=position:absolute;overflow:hidden;font-size:9px;display:flex;align-items:center;padding-left:2px;box-sizing:border-box>"), _f = /*#__PURE__*/ W("<div class=dw-preview><div style=position:relative>"), vf = .2, yf = {
	BkHeader: "#e8f0fe",
	BkDetail: "#ffffff",
	BkSummary: "#f0f0f0",
	BkFooter: "#f5f5f5"
};
function bf(e) {
	return e.replace("Bk", "").toLowerCase();
}
function xf(e) {
	return e.band.height === 0 ? null : (() => {
		var t = hf(), n = t.firstChild;
		return X(n, () => bf(e.band.tag)), N((n) => {
			var r = `${e.band.yOffset * vf}px`, i = `${e.totalWidth * vf}px`, a = `${e.band.height * vf}px`, o = yf[e.band.tag] ?? "#fff";
			return r !== n.e && Y(t, "top", n.e = r), i !== n.t && Y(t, "width", n.t = i), a !== n.a && Y(t, "height", n.a = a), o !== n.o && Y(t, "background", n.o = o), n;
		}, {
			e: void 0,
			t: void 0,
			a: void 0,
			o: void 0
		}), t;
	})();
}
function Sf(e) {
	let t = e.bands.find((t) => t.tag === e.ctrl.band)?.yOffset ?? 0, n = e.ctrl.label ?? e.ctrl.colName ?? e.ctrl.type, r = e.ctrl.type === "text";
	return (() => {
		var i = gf();
		return Y(i, "border", r ? "none" : "1px solid #bbb"), Y(i, "background", r ? "transparent" : "#fafafa"), Y(i, "color", r ? "#555" : "#222"), Y(i, "font-weight", r ? "600" : "normal"), X(i, n), N((n) => {
			var r = `${e.ctrl.x * vf}px`, a = `${(t + e.ctrl.y) * vf}px`, o = `${e.ctrl.width * vf}px`, s = `${e.ctrl.height * vf}px`;
			return r !== n.e && Y(i, "left", n.e = r), a !== n.t && Y(i, "top", n.t = a), o !== n.a && Y(i, "width", n.a = o), s !== n.o && Y(i, "height", n.o = s), n;
		}, {
			e: void 0,
			t: void 0,
			a: void 0,
			o: void 0
		}), i;
	})();
}
function Cf(e) {
	let t = () => e.layout ? mf(e.layout) : null;
	return (() => {
		var e = _f(), n = e.firstChild;
		return X(n, R(H, {
			get when() {
				return t();
			},
			children: (e) => R(Fu, {
				get naturalWidth() {
					return e().totalWidth;
				},
				get naturalHeight() {
					return e().totalHeight;
				},
				baseScale: vf,
				get children() {
					return [R(V, {
						get each() {
							return e().bands;
						},
						children: (t) => R(xf, {
							band: t,
							get totalWidth() {
								return e().totalWidth;
							}
						})
					}), R(V, {
						get each() {
							return e().controls;
						},
						children: (t) => R(Sf, {
							ctrl: t,
							get bands() {
								return e().bands;
							}
						})
					})];
				}
			})
		})), e;
	})();
}
//#endregion
//#region src/features/datawindows/DWDetail.tsx
var wf = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Controls (<!>)</h3></div><table class=data-table><thead><tr><th>Name</th><th>Type</th><th>Band</th><th>X</th><th>Y</th><th>W</th><th>H</th><th>Expr</th></tr></thead><tbody>"), Tf = /*#__PURE__*/ W("<tr><td class=name-cell></td><td></td><td><span class=\"badge badge-on\"></span></td><td></td><td></td><td></td><td></td><td style=max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px>"), Ef = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Source"), Df = /*#__PURE__*/ W("<div style=\"padding:8px 16px\"><div style=font-size:11px;color:var(--text-muted);margin-bottom:4px>Arguments</div><table class=data-table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>"), Of = /*#__PURE__*/ W("<div style=\"padding:8px 16px\"><div style=font-size:11px;color:var(--text-muted);margin-bottom:4px>WHERE Clauses</div><table class=data-table><thead><tr><th>#</th><th>Exp1</th><th>Op</th><th>Exp2</th><th>Logic</th></tr></thead><tbody>"), kf = /*#__PURE__*/ W("<div><div class=detail-body><div class=card><div class=card-header><h3>Preview</h3></div><div style=padding:4px>"), Af = /*#__PURE__*/ W("<tr><td class=name-cell></td><td>"), jf = /*#__PURE__*/ W("<tr><td></td><td></td><td><span class=\"badge badge-event\"></span></td><td></td><td><span class=\"badge badge-func\">"), Mf = /*#__PURE__*/ W("<div class=card><p style=color:var(--red)>Error: ");
function Nf(e) {
	return (() => {
		var t = wf(), n = t.firstChild, r = n.firstChild, i = r.firstChild.nextSibling;
		i.nextSibling;
		var a = n.nextSibling.firstChild.nextSibling;
		return X(r, () => e.controls.length, i), X(a, R(V, {
			get each() {
				return e.controls;
			},
			children: (e) => (() => {
				var t = Tf(), n = t.firstChild, r = n.nextSibling, i = r.nextSibling, a = i.firstChild, o = i.nextSibling, s = o.nextSibling, c = s.nextSibling, l = c.nextSibling, u = l.nextSibling;
				return X(n, () => e.control_name ?? "–"), X(r, () => e.control_type ?? ""), X(a, () => e.band ?? ""), X(o, (() => {
					var t = U(() => e.x != null);
					return () => t() ? String(e.x) : "";
				})()), X(s, (() => {
					var t = U(() => e.y != null);
					return () => t() ? String(e.y) : "";
				})()), X(c, (() => {
					var t = U(() => e.width != null);
					return () => t() ? String(e.width) : "";
				})()), X(l, (() => {
					var t = U(() => e.height != null);
					return () => t() ? String(e.height) : "";
				})()), X(u, () => e.expression ?? ""), t;
			})()
		})), t;
	})();
}
function Pf(e) {
	let t = e.d, n = e.store, [r, i] = j(!1), [a, o] = j(!1), [s, c] = j(!1), [l, u] = j(!1), d = t.retrieve_where.length > 0, f = t.arguments.length > 0, p = t.retrieve_tables.length, m = t.used_by_objects?.length ?? 0, h = t.used_by_procs?.length ?? 0, g = () => [
		...p > 0 ? [{
			label: "Tables",
			count: p,
			active: r(),
			onClick: () => i((e) => !e)
		}] : [],
		...m > 0 ? [{
			label: "Used By Objects",
			count: m,
			active: a(),
			onClick: () => o((e) => !e)
		}] : [],
		...h > 0 ? [{
			label: "Used By Procs",
			count: h,
			active: s(),
			onClick: () => c((e) => !e)
		}] : [],
		...d || f ? [{
			label: "Retrieve",
			active: l(),
			onClick: () => u((e) => !e)
		}] : []
	];
	function _(e) {
		e.key === "Escape" && (i(!1), o(!1), c(!1), u(!1));
	}
	return (() => {
		var v = kf(), y = v.firstChild, b = y.firstChild.firstChild.nextSibling;
		return v.$$keydown = _, X(v, R(Tc, {
			get name() {
				return t.name;
			},
			badgeClass: "badge-dw",
			badgeLabel: "datawindow"
		}), y), X(v, R(Gl, { get items() {
			return g();
		} }), y), X(b, R(Cf, { get layout() {
			return e.layout;
		} })), X(y, R(H, {
			get when() {
				return t.controls.length > 0;
			},
			get children() {
				return R(Nf, { get controls() {
					return t.controls;
				} });
			}
		}), null), X(y, R(H, {
			get when() {
				return t.source;
			},
			get children() {
				var e = Ef();
				return e.firstChild, X(e, R(Cd, { get code() {
					return t.source;
				} }), null), e;
			}
		}), null), X(y, R(H, {
			get when() {
				return r();
			},
			get children() {
				return R(ql, {
					title: `Tables Accessed (${p})`,
					onClose: () => i(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return t.retrieve_tables.map((e) => ({
									type: "table",
									name: e,
									onClick: () => n.dispatch({
										tag: "tables",
										action: {
											tag: "select",
											name: e
										}
									})
								}));
							}
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return a();
			},
			get children() {
				return R(ql, {
					title: `Used By — Objects (${m})`,
					onClose: () => o(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.used_by_objects ?? []).map((e) => ({
									type: "object",
									name: e,
									onClick: () => n.dispatch({
										tag: "objects",
										action: {
											tag: "select",
											name: e
										}
									})
								}));
							}
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return s();
			},
			get children() {
				return R(ql, {
					title: `Used By — Procedures (${h})`,
					onClose: () => c(!1),
					get children() {
						return R(Nc, {
							title: "",
							get items() {
								return (t.used_by_procs ?? []).map((e) => ({
									type: "procedure",
									name: e.proc,
									context: e.object,
									tooltip: `${e.object}.${e.proc}`,
									onClick: () => n.dispatch({
										tag: "objects",
										action: {
											tag: "proc-select",
											objectName: e.object,
											procName: e.proc
										}
									})
								}));
							}
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return l();
			},
			get children() {
				return R(ql, {
					title: "Retrieve Definition",
					onClose: () => u(!1),
					get children() {
						return [R(H, {
							when: f,
							get children() {
								var e = Df(), n = e.firstChild.nextSibling.firstChild.nextSibling;
								return X(n, R(V, {
									get each() {
										return t.arguments;
									},
									children: (e) => (() => {
										var t = Af(), n = t.firstChild, r = n.nextSibling;
										return X(n, () => e.arg_name), X(r, () => e.arg_type ?? ""), t;
									})()
								})), e;
							}
						}), R(H, {
							when: d,
							get children() {
								var e = Of(), n = e.firstChild.nextSibling.firstChild.nextSibling;
								return X(n, R(V, {
									get each() {
										return t.retrieve_where;
									},
									children: (e) => (() => {
										var t = jf(), n = t.firstChild, r = n.nextSibling, i = r.nextSibling, a = i.firstChild, o = i.nextSibling, s = o.nextSibling.firstChild;
										return X(n, () => String(e.idx)), X(r, () => e.exp1 ?? ""), X(a, () => e.op ?? ""), X(o, () => e.exp2 ?? ""), X(s, () => e.logic ?? ""), t;
									})()
								})), e;
							}
						})];
					}
				});
			}
		}), null), v;
	})();
}
function Ff(e) {
	let t = e.store, n = t.getState(), r = () => n().datawindows.dwDetail, i = () => n().datawindows.dwLayout;
	return [R(Dc, {
		label: "DataWindows",
		onClick: () => t.dispatch({
			tag: "datawindows",
			action: { tag: "back-to-datawindows" }
		})
	}), R(H, {
		get when() {
			return r();
		},
		get fallback() {
			return R(os, {});
		},
		children: (e) => "error" in e() ? (() => {
			var t = Mf(), n = t.firstChild;
			return n.firstChild, X(n, () => e().error, null), t;
		})() : R(Pf, {
			get d() {
				return e();
			},
			get layout() {
				return i();
			},
			store: t
		})
	})];
}
G(["keydown"]);
//#endregion
//#region src/features/datawindows/DataWindows.tsx
function If(e) {
	let t = e.store.getState();
	return R(H, {
		get when() {
			return t().datawindows.dwDetail;
		},
		get fallback() {
			return R(uf, { get store() {
				return e.store;
			} });
		},
		get children() {
			return R(Ff, { get store() {
				return e.store;
			} });
		}
	});
}
//#endregion
//#region src/features/tables/TableList.tsx
var Lf = /*#__PURE__*/ W("<div class=search-bar><input class=search-input type=text placeholder=\"Search tables…\">"), Rf = /*#__PURE__*/ W("<div class=card><div class=card-header><h2></h2></div><table class=\"data-table table-list-table\"><thead><tr><th>Table</th><th>DW refs</th><th>PS SQL refs</th><th>Total files</th></tr></thead><tbody>"), zf = /*#__PURE__*/ W("<tr><td colspan=4 style=color:var(--text-muted);padding:16px>No tables found."), Bf = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td></td><td></td><td>");
function Vf(e) {
	let t = e.store.getState(), n = () => t().tables;
	ae(() => {
		n().items.length === 0 && e.store.dispatch({
			tag: "tables",
			action: {
				tag: "search",
				q: ""
			}
		});
	}), _c({
		items: () => r().map((t) => ({ select: () => e.store.dispatch({
			tag: "tables",
			action: {
				tag: "select",
				name: t.table_name
			}
		}) })),
		tableSelector: ".table-list-table"
	});
	let r = () => {
		let e = n().q.toLowerCase();
		return e ? n().items.filter((t) => t.table_name.toLowerCase().includes(e)) : n().items;
	}, i = () => {
		let e = n().q, t = r();
		return e ? `Tables — showing ${t.length} of ${n().items.length}` : `Tables (${n().items.length})`;
	};
	return [
		(() => {
			var t = Lf(), r = t.firstChild;
			return r.$$input = (t) => {
				e.store.dispatch({
					tag: "tables",
					action: {
						tag: "filter",
						q: t.currentTarget.value
					}
				});
			}, N(() => r.value = n().q), t;
		})(),
		R(H, {
			get when() {
				return U(() => !!n().loading)() && n().items.length === 0;
			},
			get children() {
				return R(os, {});
			}
		}),
		(() => {
			var t = Rf(), n = t.firstChild, a = n.firstChild, o = n.nextSibling.firstChild.nextSibling;
			return X(a, i), X(o, R(V, {
				get each() {
					return r();
				},
				get fallback() {
					return (() => {
						var e = zf();
						return e.firstChild, e;
					})();
				},
				children: (t) => (() => {
					var n = Bf(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.nextSibling;
					return X(r, R(mc, {
						type: "table",
						get name() {
							return t.table_name;
						},
						onClick: () => e.store.dispatch({
							tag: "tables",
							action: {
								tag: "select",
								name: t.table_name
							}
						})
					})), X(i, () => String(t.dw_count)), X(a, () => String(t.ps_count)), X(o, () => String(t.file_count)), n;
				})()
			})), t;
		})()
	];
}
G(["input"]);
//#endregion
//#region src/components/detail/ColumnRow.tsx
var Hf = /*#__PURE__*/ W("<span style=color:var(--text-muted)>(none)"), Uf = /*#__PURE__*/ W("<div> · "), Wf = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell> </td><td> DW</td><td> PS read</td><td> PS write"), Gf = /*#__PURE__*/ W("<tr><td colspan=4 style=\"padding:8px 16px;background:var(--bg-secondary)\"><div style=margin-bottom:6px><strong>DW readers:</strong> </div><div style=margin-bottom:6px><strong>PS readers:</strong></div><div><strong>PS writers:");
function Kf(e) {
	return R(H, {
		get when() {
			return e.refs.length > 0;
		},
		get fallback() {
			return Hf();
		},
		get children() {
			return R(V, {
				get each() {
					return e.refs;
				},
				children: (e) => (() => {
					var t = Uf(), n = t.firstChild;
					return X(t, () => e.object, n), X(t, (() => {
						var t = U(() => !!e.proc_name);
						return () => t() ? ` / ${e.proc_name}` : "";
					})(), n), X(t, () => e.operation, null), t;
				})()
			});
		}
	});
}
function qf(e) {
	let [t, n] = j(!1), r = e.col;
	return [(() => {
		var e = Wf(), i = e.firstChild, a = i.firstChild, o = i.nextSibling, s = o.firstChild, c = o.nextSibling, l = c.firstChild, u = c.nextSibling, d = u.firstChild;
		return e.$$click = () => n(!t()), X(i, (() => {
			var e = U(() => !!t());
			return () => e() ? R(bi, { size: 12 }) : R(wi, { size: 12 });
		})(), a), X(i, () => r.column, null), X(o, () => r.dw_readers.length, s), X(o, () => r.dw_readers.length === 1 ? "" : "s", null), X(c, () => r.ps_readers.length, l), X(c, () => r.ps_readers.length === 1 ? "" : "s", null), X(u, () => r.ps_writers.length, d), X(u, () => r.ps_writers.length === 1 ? "" : "s", null), e;
	})(), R(H, {
		get when() {
			return t();
		},
		get children() {
			var e = Gf(), t = e.firstChild.firstChild;
			t.firstChild.nextSibling;
			var n = t.nextSibling;
			n.firstChild;
			var i = n.nextSibling;
			return i.firstChild, X(t, R(H, {
				get when() {
					return r.dw_readers.length > 0;
				},
				get fallback() {
					return Hf();
				},
				get children() {
					return r.dw_readers.join("  ");
				}
			}), null), X(n, R(Kf, { get refs() {
				return r.ps_readers;
			} }), null), X(i, R(Kf, { get refs() {
				return r.ps_writers;
			} }), null), e;
		}
	})];
}
G(["click"]);
//#endregion
//#region src/features/tables/TableDetail.tsx
var Jf = /*#__PURE__*/ W("<table class=data-table><thead><tr><th>Object</th><th>Procedure</th><th>Operation</th></tr></thead><tbody>"), Yf = /*#__PURE__*/ W("<tr><td colspan=3 style=color:var(--text-muted);padding:12px>None."), Xf = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td></td><td><span>"), Zf = /*#__PURE__*/ W("<div><div class=card-header style=\"padding:8px 16px\"><h3>Direct Access (<!>)</h3></div><table class=data-table><thead><tr><th>Object</th><th>Source</th><th>Operation</th></tr></thead><tbody>"), Qf = /*#__PURE__*/ W("<div><div class=card-header style=\"padding:8px 16px\"><h3>Inherited Access (<!>)"), $f = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td><span></span></td><td>"), ep = /*#__PURE__*/ W("<table class=data-table><thead><tr><th colspan=2>depth </th></tr></thead><tbody>"), tp = /*#__PURE__*/ W("<tr><td class=name-cell style=\"padding:4px 8px\"></td><td style=color:var(--text-muted)>inherits from "), np = /*#__PURE__*/ W("<p style=color:var(--text-muted);margin:0;font-size:13px> DW reader<!> · <!> procedure reader<!> · <!> writer"), rp = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Columns (<!>)</h3></div><table class=data-table><thead><tr><th>Column</th><th>DW reads</th><th>PS reads</th><th>PS writes</th></tr></thead><tbody>"), ip = /*#__PURE__*/ W("<div class=entity-card-list style=\"padding:8px 16px\">"), ap = /*#__PURE__*/ W("<div><div class=detail-body>"), op = /*#__PURE__*/ W("<div class=card style=padding:32px;text-align:center;color:var(--text-muted)>No column-level data available for this table."), sp = /*#__PURE__*/ W("<p style=\"color:var(--text-muted);padding:12px 16px\">None."), cp = /*#__PURE__*/ W("<div class=card><p style=color:var(--red);padding:16px>Error: "), lp = new Set([
	"INSERT",
	"UPDATE",
	"DELETE"
]), up = {
	INSERT: "badge-func",
	UPDATE: "badge-event",
	DELETE: "badge-dw"
};
function dp(e) {
	return (() => {
		var t = Jf(), n = t.firstChild.nextSibling;
		return X(n, R(V, {
			get each() {
				return e.rows;
			},
			get fallback() {
				return (() => {
					var e = Yf();
					return e.firstChild, e;
				})();
			},
			children: (t) => (() => {
				var n = Xf(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling.firstChild;
				return X(r, R(mc, {
					type: "object",
					get name() {
						return t.object;
					},
					onClick: () => e.store.dispatch({
						tag: "objects",
						action: {
							tag: "select",
							name: t.object
						}
					})
				})), X(i, () => t.proc_name ?? "–"), X(a, () => t.operation), N(() => q(a, `badge ${up[t.operation] ?? "badge-on"}`)), n;
			})()
		})), t;
	})();
}
function fp(e) {
	let t = /* @__PURE__ */ new Map();
	for (let n of e) {
		let e = t.get(n.depth);
		e ? e.push(n) : t.set(n.depth, [n]);
	}
	return [...t.entries()].sort((e, t) => e[0] - t[0]);
}
function pp(e) {
	return [(() => {
		var t = Zf(), n = t.firstChild, r = n.firstChild, i = r.firstChild.nextSibling;
		i.nextSibling;
		var a = n.nextSibling.firstChild.nextSibling;
		return X(r, () => e.direct.length, i), X(a, R(V, {
			get each() {
				return e.direct;
			},
			get fallback() {
				return (() => {
					var e = Yf();
					return e.firstChild, e;
				})();
			},
			children: (t) => (() => {
				var n = $f(), r = n.firstChild, i = r.nextSibling, a = i.firstChild, o = i.nextSibling;
				return X(r, R(mc, {
					get type() {
						return t.source === "datawindow" ? "datawindow" : "object";
					},
					get name() {
						return t.object;
					},
					onClick: () => e.store.dispatch(t.source === "datawindow" ? {
						tag: "datawindows",
						action: {
							tag: "select",
							name: t.object
						}
					} : {
						tag: "objects",
						action: {
							tag: "select",
							name: t.object
						}
					})
				})), X(a, () => t.source), X(o, () => t.operation), N(() => q(a, `badge ${t.source === "datawindow" ? "badge-dw" : "badge-on"}`)), n;
			})()
		})), t;
	})(), R(H, {
		get when() {
			return e.inherited.length > 0;
		},
		get children() {
			var t = Qf(), n = t.firstChild.firstChild, r = n.firstChild.nextSibling;
			return r.nextSibling, X(n, () => e.inherited.length, r), X(t, R(V, {
				get each() {
					return fp(e.inherited);
				},
				children: ([t, n]) => (() => {
					var r = ep(), i = r.firstChild, a = i.firstChild.firstChild;
					a.firstChild;
					var o = i.nextSibling;
					return X(a, t, null), X(o, R(V, {
						each: n,
						children: (t) => (() => {
							var n = tp(), r = n.firstChild, i = r.nextSibling;
							return i.firstChild, X(r, R(mc, {
								type: "object",
								get name() {
									return t.descendant;
								},
								onClick: () => e.store.dispatch({
									tag: "objects",
									action: {
										tag: "select",
										name: t.descendant
									}
								})
							})), X(i, () => t.ancestor, null), n;
						})()
					})), r;
				})()
			}), null), t;
		}
	})];
}
function mp(e) {
	let t = e.detail, n = e.store, [r, i] = j(!1), [a, o] = j(!1), [s, c] = j(!1), [l, u] = j(!1), d = t.procedures.filter((e) => !lp.has(e.operation)), f = t.procedures.filter((e) => lp.has(e.operation)), p = t.impact, m = p.direct.length + p.inherited.length, h = m > 0, g = () => [
		{
			label: "DW Readers",
			count: t.datawindows.length,
			active: r(),
			onClick: () => i((e) => !e)
		},
		{
			label: "Readers",
			count: d.length,
			active: a(),
			onClick: () => o((e) => !e)
		},
		{
			label: "Writers",
			count: f.length,
			active: s(),
			onClick: () => c((e) => !e)
		},
		...h ? [{
			label: "Impact",
			count: m,
			active: l(),
			onClick: () => u((e) => !e)
		}] : []
	];
	function _(e) {
		e.key === "Escape" && (i(!1), o(!1), c(!1), u(!1));
	}
	let v = (() => {
		var e = np(), n = e.firstChild, r = n.nextSibling, i = r.nextSibling.nextSibling, a = i.nextSibling.nextSibling, o = a.nextSibling.nextSibling;
		return o.nextSibling, X(e, () => t.dw_count, n), X(e, () => t.dw_count === 1 ? "" : "s", r), X(e, () => d.length, i), X(e, () => d.length === 1 ? "" : "s", a), X(e, () => f.length, o), X(e, () => f.length === 1 ? "" : "s", null), e;
	})();
	return (() => {
		var h = ap(), y = h.firstChild;
		return h.$$keydown = _, X(h, R(Tc, {
			get name() {
				return t.table_name;
			},
			badgeClass: "badge-dw",
			badgeLabel: "table",
			subtitle: v
		}), y), X(h, R(Gl, { get items() {
			return g();
		} }), y), X(y, R(H, {
			get when() {
				return t.columns_detail.length > 0;
			},
			get fallback() {
				return op();
			},
			get children() {
				var n = rp(), r = n.firstChild, i = r.firstChild, a = i.firstChild.nextSibling;
				a.nextSibling;
				var o = r.nextSibling.firstChild.nextSibling;
				return X(i, () => t.columns_detail.length, a), X(o, R(V, {
					get each() {
						return t.columns_detail;
					},
					children: (t) => R(qf, {
						col: t,
						get store() {
							return e.store;
						}
					})
				})), n;
			}
		}), null), X(y, R(H, {
			get when() {
				return r();
			},
			get children() {
				return R(ql, {
					get title() {
						return `DataWindow Readers (${t.datawindows.length})`;
					},
					onClose: () => i(!1),
					get children() {
						return R(H, {
							get when() {
								return t.datawindows.length > 0;
							},
							get fallback() {
								return sp();
							},
							get children() {
								var e = ip();
								return X(e, R(V, {
									get each() {
										return t.datawindows;
									},
									children: (e) => R(mc, {
										type: "datawindow",
										get name() {
											return e.dw_name;
										},
										onClick: () => n.dispatch({
											tag: "datawindows",
											action: {
												tag: "select",
												name: e.dw_name
											}
										})
									})
								})), e;
							}
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return a();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Procedure Readers — SELECT (${d.length})`;
					},
					onClose: () => o(!1),
					get children() {
						return R(dp, {
							rows: d,
							store: n
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return s();
			},
			get children() {
				return R(ql, {
					get title() {
						return `Procedure Writers — INSERT / UPDATE / DELETE (${f.length})`;
					},
					onClose: () => c(!1),
					get children() {
						return R(dp, {
							rows: f,
							store: n
						});
					}
				});
			}
		}), null), X(y, R(H, {
			get when() {
				return l();
			},
			get children() {
				return R(ql, {
					title: `Impact (${m})`,
					onClose: () => u(!1),
					get children() {
						return R(pp, {
							get direct() {
								return p.direct;
							},
							get inherited() {
								return p.inherited;
							},
							store: n
						});
					}
				});
			}
		}), null), h;
	})();
}
function hp(e) {
	let t = e.store.getState(), n = () => t().tables;
	return [R(Dc, {
		label: "Tables",
		onClick: () => e.store.dispatch({
			tag: "tables",
			action: { tag: "back" }
		})
	}), R(H, {
		get when() {
			return n().detail;
		},
		get fallback() {
			return R(H, {
				get when() {
					return n().error;
				},
				get fallback() {
					return R(os, {});
				},
				get children() {
					var e = cp(), t = e.firstChild;
					return t.firstChild, X(t, () => n().error, null), e;
				}
			});
		},
		children: (t) => R(mp, {
			get detail() {
				return t();
			},
			get store() {
				return e.store;
			}
		})
	})];
}
G(["keydown"]);
//#endregion
//#region src/features/tables/Tables.tsx
function gp(e) {
	let t = e.store.getState();
	return R(H, {
		get when() {
			return t().nav.route.view === "tableDetail";
		},
		get fallback() {
			return R(Vf, { get store() {
				return e.store;
			} });
		},
		get children() {
			return R(hp, { get store() {
				return e.store;
			} });
		}
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/XTJD7L6B.jsx
var _p = class {
	collection;
	direction;
	orientation;
	constructor(e, t, n) {
		this.collection = e, this.direction = t, this.orientation = n;
	}
	flipDirection() {
		return this.direction() === "rtl" && this.orientation() === "horizontal";
	}
	getKeyLeftOf(e) {
		if (this.flipDirection()) return this.getNextKey(e);
		if (this.orientation() === "horizontal") return this.getPreviousKey(e);
	}
	getKeyRightOf(e) {
		if (this.flipDirection()) return this.getPreviousKey(e);
		if (this.orientation() === "horizontal") return this.getNextKey(e);
	}
	getKeyAbove(e) {
		if (this.orientation() === "vertical") return this.getPreviousKey(e);
	}
	getKeyBelow(e) {
		if (this.orientation() === "vertical") return this.getNextKey(e);
	}
	getFirstKey() {
		let e = this.collection().getFirstKey();
		if (e != null) return this.collection().getItem(e)?.disabled && (e = this.getNextKey(e)), e;
	}
	getLastKey() {
		let e = this.collection().getLastKey();
		if (e != null) return this.collection().getItem(e)?.disabled && (e = this.getPreviousKey(e)), e;
	}
	getNextKey(e) {
		let t = e, n;
		do
			if (t = this.collection().getKeyAfter(t) ?? this.collection().getFirstKey(), t == null || (n = this.collection().getItem(t), n == null)) return;
		while (n.disabled);
		return t;
	}
	getPreviousKey(e) {
		let t = e, n;
		do
			if (t = this.collection().getKeyBefore(t) ?? this.collection().getLastKey(), t == null || (n = this.collection().getItem(t), n == null)) return;
		while (n.disabled);
		return t;
	}
}, vp = !1, yp = (e) => e != null, bp = (e) => e.filter(yp);
function xp(e) {
	return (...t) => {
		for (let n of e) n && n(...t);
	};
}
var $ = (e) => typeof e == "function" && !e.length ? e() : e, Sp = (e) => Array.isArray(e) ? e : e ? [e] : [];
function Cp(e, ...t) {
	return typeof e == "function" ? e(...t) : e;
}
var wp = vp ? (e) => oe() ? L(e) : e : L;
function Tp(e, t, n, r) {
	let i = e.length, a = t.length, o = 0;
	if (!a) {
		for (; o < i; o++) n(e[o]);
		return;
	}
	if (!i) {
		for (; o < a; o++) r(t[o]);
		return;
	}
	for (; o < a && t[o] === e[o]; o++);
	let s, c;
	t = t.slice(o), e = e.slice(o);
	for (s of t) e.includes(s) || r(s);
	for (c of e) t.includes(c) || n(c);
}
//#endregion
//#region node_modules/.pnpm/@solid-primitives+event-listener@2.4.5_solid-js@1.9.13/node_modules/@solid-primitives/event-listener/dist/eventListener.js
function Ep(e, t, n, r) {
	return e.addEventListener(t, n, r), wp(e.removeEventListener.bind(e, t, n, r));
}
function Dp(e, t, n, r) {
	let i = () => {
		Sp($(e)).forEach((e) => {
			e && Sp($(t)).forEach((t) => Ep(e, t, n, r));
		});
	};
	typeof e == "function" ? P(i) : N(i);
}
//#endregion
//#region node_modules/.pnpm/@solid-primitives+keyed@1.5.3_solid-js@1.9.13/node_modules/@solid-primitives/keyed/dist/index.js
var Op = Symbol("fallback");
function kp(e) {
	for (let t of e) t.dispose();
}
function Ap(e, t, n, r = {}) {
	let i = /* @__PURE__ */ new Map();
	return L(() => kp(i.values())), () => {
		let n = e() || [];
		return n[g], I(() => {
			if (!n.length) return kp(i.values()), i.clear(), r.fallback ? [A((e) => (i.set(Op, { dispose: e }), r.fallback()))] : [];
			let e = Array(n.length), o = i.get(Op);
			if (!i.size || o) {
				o?.dispose(), i.delete(Op);
				for (let r = 0; r < n.length; r++) {
					let i = n[r], o = t(i, r);
					a(e, i, r, o);
				}
				return e;
			}
			let s = new Set(i.keys());
			for (let r = 0; r < n.length; r++) {
				let o = n[r], c = t(o, r);
				s.delete(c);
				let l = i.get(c);
				l ? (e[r] = l.mapped, l.setIndex?.(r), l.setItem(() => o)) : a(e, o, r, c);
			}
			for (let e of s) i.get(e)?.dispose(), i.delete(e);
			return e;
		});
	};
	function a(e, t, r, a) {
		A((o) => {
			let [s, c] = j(t), l = {
				setItem: c,
				dispose: o
			};
			if (n.length > 1) {
				let [e, t] = j(r);
				l.setIndex = t, l.mapped = n(s, e);
			} else l.mapped = n(s);
			i.set(a, l), e[r] = l.mapped;
		});
	}
}
function jp(e) {
	let { by: t } = e;
	return F(Ap(() => e.each, typeof t == "function" ? t : (e) => e[t], e.children, "fallback" in e ? { fallback: () => e.fallback } : void 0));
}
//#endregion
//#region node_modules/.pnpm/@solid-primitives+props@3.2.3_solid-js@1.9.13/node_modules/@solid-primitives/props/dist/combineProps.js
var Mp = /((?:--)?(?:\w+-?)+)\s*:\s*([^;]*)/g;
function Np(e) {
	let t = {}, n;
	for (; n = Mp.exec(e);) t[n[1]] = n[2];
	return t;
}
function Pp(e, t) {
	if (typeof e == "string") {
		if (typeof t == "string") return `${e};${t}`;
		e = Np(e);
	} else typeof t == "string" && (t = Np(t));
	return {
		...e,
		...t
	};
}
//#endregion
//#region node_modules/.pnpm/@solid-primitives+refs@1.1.3_solid-js@1.9.13/node_modules/@solid-primitives/refs/dist/index.js
function Fp(...e) {
	return xp(e);
}
//#endregion
//#region node_modules/.pnpm/@kobalte+utils@0.9.1_solid-js@1.9.13/node_modules/@kobalte/utils/dist/index.js
function Ip(e, t, n = -1) {
	return n in e ? [
		...e.slice(0, n),
		t,
		...e.slice(n)
	] : [...e, t];
}
function Lp(e, t) {
	let n = [...e], r = n.indexOf(t);
	return r !== -1 && n.splice(r, 1), n;
}
function Rp(e) {
	return typeof e == "number";
}
function zp(e) {
	return Object.prototype.toString.call(e) === "[object String]";
}
function Bp(e) {
	return typeof e == "function";
}
function Vp(e) {
	return (t) => `${e()}-${t}`;
}
function Hp(e, t) {
	return e ? e === t || e.contains(t) : !1;
}
function Up(e, t = !1) {
	let { activeElement: n } = Gp(e);
	if (!n?.nodeName) return null;
	if (Kp(n) && n.contentDocument) return Up(n.contentDocument.body, t);
	if (t) {
		let e = n.getAttribute("aria-activedescendant");
		if (e) {
			let t = Gp(n).getElementById(e);
			if (t) return t;
		}
	}
	return n;
}
function Wp(e) {
	return Gp(e).defaultView || window;
}
function Gp(e) {
	return e ? e.ownerDocument || e : document;
}
function Kp(e) {
	return e.tagName === "IFRAME";
}
var qp = /* @__PURE__ */ ((e) => (e.Escape = "Escape", e.Enter = "Enter", e.Tab = "Tab", e.Space = " ", e.ArrowDown = "ArrowDown", e.ArrowLeft = "ArrowLeft", e.ArrowRight = "ArrowRight", e.ArrowUp = "ArrowUp", e.End = "End", e.Home = "Home", e.PageDown = "PageDown", e.PageUp = "PageUp", e))(qp || {});
function Jp(e) {
	return typeof window > "u" || window.navigator == null ? !1 : window.navigator.userAgentData?.brands.some((t) => e.test(t.brand)) || e.test(window.navigator.userAgent);
}
function Yp(e) {
	return typeof window < "u" && window.navigator != null ? e.test(window.navigator.userAgentData?.platform || window.navigator.platform) : !1;
}
function Xp() {
	return Yp(/^Mac/i);
}
function Zp() {
	return Yp(/^iPhone/i);
}
function Qp() {
	return Yp(/^iPad/i) || Xp() && navigator.maxTouchPoints > 1;
}
function $p() {
	return Zp() || Qp();
}
function em() {
	return Xp() || $p();
}
function tm() {
	return Jp(/AppleWebKit/i) && !nm();
}
function nm() {
	return Jp(/Chrome/i);
}
function rm(e, t) {
	return t && (Bp(t) ? t(e) : t[0](t[1], e)), e?.defaultPrevented;
}
function im(e) {
	return (t) => {
		for (let n of e) rm(t, n);
	};
}
function am(e) {
	return Xp() ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
}
function om(e) {
	if (e) if (cm()) e.focus({ preventScroll: !0 });
	else {
		let t = lm(e);
		e.focus(), um(t);
	}
}
var sm = null;
function cm() {
	if (sm == null) {
		sm = !1;
		try {
			document.createElement("div").focus({ get preventScroll() {
				return sm = !0, !0;
			} });
		} catch {}
	}
	return sm;
}
function lm(e) {
	let t = e.parentNode, n = [], r = document.scrollingElement || document.documentElement;
	for (; t instanceof HTMLElement && t !== r;) (t.offsetHeight < t.scrollHeight || t.offsetWidth < t.scrollWidth) && n.push({
		element: t,
		scrollTop: t.scrollTop,
		scrollLeft: t.scrollLeft
	}), t = t.parentNode;
	return r instanceof HTMLElement && n.push({
		element: r,
		scrollTop: r.scrollTop,
		scrollLeft: r.scrollLeft
	}), n;
}
function um(e) {
	for (let { element: t, scrollTop: n, scrollLeft: r } of e) t.scrollTop = n, t.scrollLeft = r;
}
var dm = [
	"input:not([type='hidden']):not([disabled])",
	"select:not([disabled])",
	"textarea:not([disabled])",
	"button:not([disabled])",
	"a[href]",
	"area[href]",
	"[tabindex]",
	"iframe",
	"object",
	"embed",
	"audio[controls]",
	"video[controls]",
	"[contenteditable]:not([contenteditable='false'])"
], fm = [...dm, "[tabindex]:not([tabindex=\"-1\"]):not([disabled])"], pm = `${dm.join(":not([hidden]),")},[tabindex]:not([disabled]):not([hidden])`, mm = fm.join(":not([hidden]):not([tabindex=\"-1\"]),");
function hm(e, t) {
	let n = Array.from(e.querySelectorAll(pm)).filter(gm);
	return t && gm(e) && n.unshift(e), n.forEach((e, t) => {
		if (Kp(e) && e.contentDocument) {
			let r = e.contentDocument.body, i = hm(r, !1);
			n.splice(t, 1, ...i);
		}
	}), n;
}
function gm(e) {
	return _m(e) && !vm(e);
}
function _m(e) {
	return e.matches(pm) && ym(e);
}
function vm(e) {
	return Number.parseInt(e.getAttribute("tabindex") || "0", 10) < 0;
}
function ym(e, t) {
	return e.nodeName !== "#comment" && bm(e) && xm(e, t) && (!e.parentElement || ym(e.parentElement, e));
}
function bm(e) {
	if (!(e instanceof HTMLElement) && !(e instanceof SVGElement)) return !1;
	let { display: t, visibility: n } = e.style, r = t !== "none" && n !== "hidden" && n !== "collapse";
	if (r) {
		if (!e.ownerDocument.defaultView) return r;
		let { getComputedStyle: t } = e.ownerDocument.defaultView, { display: n, visibility: i } = t(e);
		r = n !== "none" && i !== "hidden" && i !== "collapse";
	}
	return r;
}
function xm(e, t) {
	return !e.hasAttribute("hidden") && (e.nodeName === "DETAILS" && t && t.nodeName !== "SUMMARY" ? e.hasAttribute("open") : !0);
}
function Sm(e, t) {
	return t.some((t) => t.contains(e));
}
function Cm(e, t, n) {
	let r = t?.tabbable ? mm : pm, i = document.createTreeWalker(e, NodeFilter.SHOW_ELEMENT, { acceptNode(e) {
		return t?.from?.contains(e) ? NodeFilter.FILTER_REJECT : e.matches(r) && ym(e) && (!n || Sm(e, n)) && (!t?.accept || t.accept(e)) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
	} });
	return t?.from && (i.currentNode = t.from), i;
}
function wm() {}
function Tm(e, t) {
	return z(e, t);
}
var Em = /* @__PURE__ */ new Map(), Dm = /* @__PURE__ */ new Set();
function Om() {
	if (typeof window > "u") return;
	let e = (e) => {
		if (!e.target) return;
		let n = Em.get(e.target);
		n || (n = /* @__PURE__ */ new Set(), Em.set(e.target, n), e.target.addEventListener("transitioncancel", t)), n.add(e.propertyName);
	}, t = (e) => {
		if (!e.target) return;
		let n = Em.get(e.target);
		if (n && (n.delete(e.propertyName), n.size === 0 && (e.target.removeEventListener("transitioncancel", t), Em.delete(e.target)), Em.size === 0)) {
			for (let e of Dm) e();
			Dm.clear();
		}
	};
	document.body.addEventListener("transitionrun", e), document.body.addEventListener("transitionend", t);
}
typeof document < "u" && (document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", Om) : Om());
function km(e, t) {
	let n = Am(e, t, "left"), r = Am(e, t, "top"), i = t.offsetWidth, a = t.offsetHeight, o = e.scrollLeft, s = e.scrollTop, c = o + e.offsetWidth, l = s + e.offsetHeight;
	n <= o ? o = n : n + i > c && (o += n + i - c), r <= s ? s = r : r + a > l && (s += r + a - l), e.scrollLeft = o, e.scrollTop = s;
}
function Am(e, t, n) {
	let r = n === "left" ? "offsetLeft" : "offsetTop", i = 0;
	for (; t.offsetParent && (i += t[r], t.offsetParent !== e);) {
		if (t.offsetParent.contains(e)) {
			i -= e[r];
			break;
		}
		t = t.offsetParent;
	}
	return i;
}
var jm = {
	border: "0",
	clip: "rect(0 0 0 0)",
	"clip-path": "inset(50%)",
	height: "1px",
	margin: "0 -1px -1px 0",
	overflow: "hidden",
	padding: "0",
	position: "absolute",
	width: "1px",
	"white-space": "nowrap"
};
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/YRH543JR.jsx
function Mm(e) {
	let t = e.startIndex ?? 0, n = e.startLevel ?? 0, r = [], i = (t) => {
		if (t == null) return "";
		let n = e.getKey ?? "key", r = zp(n) ? t[n] : n(t);
		return r == null ? "" : String(r);
	}, a = (t) => {
		if (t == null) return "";
		let n = e.getTextValue ?? "textValue", r = zp(n) ? t[n] : n(t);
		return r == null ? "" : String(r);
	}, o = (t) => {
		if (t == null) return !1;
		let n = e.getDisabled ?? "disabled";
		return (zp(n) ? t[n] : n(t)) ?? !1;
	}, s = (t) => {
		if (t != null) return zp(e.getSectionChildren) ? t[e.getSectionChildren] : e.getSectionChildren?.(t);
	};
	for (let c of e.dataSource) {
		if (zp(c) || Rp(c)) {
			r.push({
				type: "item",
				rawValue: c,
				key: String(c),
				textValue: String(c),
				disabled: o(c),
				level: n,
				index: t
			}), t++;
			continue;
		}
		if (s(c) != null) {
			r.push({
				type: "section",
				rawValue: c,
				key: "",
				textValue: "",
				disabled: !1,
				level: n,
				index: t
			}), t++;
			let i = s(c) ?? [];
			if (i.length > 0) {
				let a = Mm({
					dataSource: i,
					getKey: e.getKey,
					getTextValue: e.getTextValue,
					getDisabled: e.getDisabled,
					getSectionChildren: e.getSectionChildren,
					startIndex: t,
					startLevel: n + 1
				});
				r.push(...a), t += a.length;
			}
		} else r.push({
			type: "item",
			rawValue: c,
			key: i(c),
			textValue: a(c),
			disabled: o(c),
			level: n,
			index: t
		}), t++;
	}
	return r;
}
function Nm(e, t = []) {
	return F(() => {
		let n = Mm({
			dataSource: $(e.dataSource),
			getKey: $(e.getKey),
			getTextValue: $(e.getTextValue),
			getDisabled: $(e.getDisabled),
			getSectionChildren: $(e.getSectionChildren)
		});
		for (let e = 0; e < t.length; e++) t[e]();
		return e.factory(n);
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/LR7LBJN3.jsx
var Pm = /* @__PURE__ */ new Set([
	"Avst",
	"Arab",
	"Armi",
	"Syrc",
	"Samr",
	"Mand",
	"Thaa",
	"Mend",
	"Nkoo",
	"Adlm",
	"Rohg",
	"Hebr"
]), Fm = /* @__PURE__ */ new Set([
	"ae",
	"ar",
	"arc",
	"bcc",
	"bqi",
	"ckb",
	"dv",
	"fa",
	"glk",
	"he",
	"ku",
	"mzn",
	"nqo",
	"pnb",
	"ps",
	"sd",
	"ug",
	"ur",
	"yi"
]);
function Im(e) {
	if (Intl.Locale) {
		let t = new Intl.Locale(e).maximize().script ?? "";
		return Pm.has(t);
	}
	let t = e.split("-")[0];
	return Fm.has(t);
}
function Lm(e) {
	return Im(e) ? "rtl" : "ltr";
}
function Rm() {
	let e = typeof navigator < "u" && (navigator.language || navigator.userLanguage) || "en-US";
	try {
		Intl.DateTimeFormat.supportedLocalesOf([e]);
	} catch {
		e = "en-US";
	}
	return {
		locale: e,
		direction: Lm(e)
	};
}
var zm = Rm(), Bm = /* @__PURE__ */ new Set();
function Vm() {
	zm = Rm();
	for (let e of Bm) e(zm);
}
function Hm() {
	let [e, t] = j(zm), n = F(() => e());
	return ae(() => {
		Bm.size === 0 && window.addEventListener("languagechange", Vm), Bm.add(t), L(() => {
			Bm.delete(t), Bm.size === 0 && window.removeEventListener("languagechange", Vm);
		});
	}), {
		locale: () => n().locale,
		direction: () => n().direction
	};
}
var Um = de();
function Wm() {
	let e = Hm();
	return fe(Um) || e;
}
var Gm = /* @__PURE__ */ new Map();
function Km(e) {
	let { locale: t } = Wm(), n = F(() => t() + (e ? Object.entries(e).sort((e, t) => e[0] < t[0] ? -1 : 1).join() : ""));
	return F(() => {
		let r = n(), i;
		return Gm.has(r) && (i = Gm.get(r)), i || (i = new Intl.Collator(t(), e), Gm.set(r, i)), i;
	});
}
function qm(e) {
	let t = Km({
		usage: "search",
		...e
	});
	return {
		startsWith: (e, n) => {
			if (n.length === 0) return !0;
			let r = e.normalize("NFC"), i = n.normalize("NFC");
			return t().compare(r.slice(0, i.length), i) === 0;
		},
		endsWith: (e, n) => {
			if (n.length === 0) return !0;
			let r = e.normalize("NFC"), i = n.normalize("NFC");
			return t().compare(r.slice(-i.length), i) === 0;
		},
		contains: (e, n) => {
			if (n.length === 0) return !0;
			let r = e.normalize("NFC"), i = n.normalize("NFC"), a = 0, o = n.length;
			for (; a + o <= r.length; a++) {
				let e = r.slice(a, a + o);
				if (t().compare(i, e) === 0) return !0;
			}
			return !1;
		}
	};
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/FN6EICGO.jsx
function Jm(e) {
	let [t, n] = j(e.defaultValue?.()), r = F(() => e.value?.() !== void 0), i = F(() => r() ? e.value?.() : t());
	return [i, (t) => {
		I(() => {
			let a = Cp(t, i());
			return Object.is(a, i()) || (r() || n(a), e.onChange?.(a)), a;
		});
	}];
}
function Ym(e) {
	let [t, n] = Jm(e);
	return [() => t() ?? !1, n];
}
function Xm(e) {
	let [t, n] = Jm(e);
	return [() => t() ?? [], n];
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/QZDH5R5B.jsx
var Zm = class e extends Set {
	anchorKey;
	currentKey;
	constructor(t, n, r) {
		super(t), t instanceof e ? (this.anchorKey = n || t.anchorKey, this.currentKey = r || t.currentKey) : (this.anchorKey = n, this.currentKey = r);
	}
};
function Qm(e) {
	let [t, n] = Jm(e);
	return [() => t() ?? new Zm(), n];
}
function $m(e) {
	return em() ? e.altKey : e.ctrlKey;
}
function eh(e) {
	return Xp() ? e.metaKey : e.ctrlKey;
}
function th(e) {
	return new Zm(e);
}
function nh(e, t) {
	if (e.size !== t.size) return !1;
	for (let n of e) if (!t.has(n)) return !1;
	return !0;
}
function rh(e) {
	let t = Tm({
		selectionMode: "none",
		selectionBehavior: "toggle"
	}, e), [n, r] = j(!1), [i, a] = j(), [o, s] = Qm({
		value: F(() => {
			let e = $(t.selectedKeys);
			return e == null ? e : th(e);
		}),
		defaultValue: F(() => {
			let e = $(t.defaultSelectedKeys);
			return e == null ? new Zm() : th(e);
		}),
		onChange: (e) => t.onSelectionChange?.(e)
	}), [c, l] = j($(t.selectionBehavior));
	return P(() => {
		let e = o();
		$(t.selectionBehavior) === "replace" && c() === "toggle" && typeof e == "object" && e.size === 0 && l("replace");
	}), P(() => {
		l($(t.selectionBehavior) ?? "toggle");
	}), {
		selectionMode: () => $(t.selectionMode),
		disallowEmptySelection: () => $(t.disallowEmptySelection) ?? !1,
		selectionBehavior: c,
		setSelectionBehavior: l,
		isFocused: n,
		setFocused: r,
		focusedKey: i,
		setFocusedKey: a,
		selectedKeys: o,
		setSelectedKeys: (e) => {
			($(t.allowDuplicateSelectionEvents) || !nh(e, o())) && s(e);
		}
	};
}
function ih(e) {
	let [t, n] = j(""), [r, i] = j(-1);
	return { typeSelectHandlers: { onKeyDown: (a) => {
		if ($(e.isDisabled)) return;
		let o = $(e.keyboardDelegate), s = $(e.selectionManager);
		if (!o.getKeyForSearch) return;
		let c = ah(a.key);
		if (!c || a.ctrlKey || a.metaKey) return;
		c === " " && t().trim().length > 0 && (a.preventDefault(), a.stopPropagation());
		let l = n((e) => e + c), u = o.getKeyForSearch(l, s.focusedKey()) ?? o.getKeyForSearch(l);
		u == null && oh(l) && (l = l[0], u = o.getKeyForSearch(l, s.focusedKey()) ?? o.getKeyForSearch(l)), u != null && (s.setFocusedKey(u), e.onTypeSelect?.(u)), clearTimeout(r()), i(window.setTimeout(() => n(""), 500));
	} } };
}
function ah(e) {
	return e.length === 1 || !/^[A-Z]/i.test(e) ? e : "";
}
function oh(e) {
	return e.split("").every((t) => t === e[0]);
}
function sh(e, t, n) {
	let r = z({ selectOnFocus: () => $(e.selectionManager).selectionBehavior() === "replace" }, e), i = () => n?.() ?? t(), { direction: a } = Wm(), o = {
		top: 0,
		left: 0
	};
	Dp(() => $(r.isVirtualized) ? void 0 : i(), "scroll", () => {
		let e = i();
		e && (o = {
			top: e.scrollTop,
			left: e.scrollLeft
		});
	});
	let { typeSelectHandlers: s } = ih({
		isDisabled: () => $(r.disallowTypeAhead),
		keyboardDelegate: () => $(r.keyboardDelegate),
		selectionManager: () => $(r.selectionManager)
	}), c = () => $(r.orientation) ?? "vertical", l = (e) => {
		rm(e, s.onKeyDown), e.altKey && e.key === "Tab" && e.preventDefault();
		let n = t();
		if (!n?.contains(e.target)) return;
		let i = $(r.selectionManager), o = $(r.selectOnFocus), l = (t) => {
			t != null && (i.setFocusedKey(t), e.shiftKey && i.selectionMode() === "multiple" ? i.extendSelection(t) : o && !$m(e) && i.replaceSelection(t));
		}, u = $(r.keyboardDelegate), d = $(r.shouldFocusWrap), f = i.focusedKey();
		switch (e.key) {
			case c() === "vertical" ? "ArrowDown" : "ArrowRight":
				if (u.getKeyBelow) {
					e.preventDefault();
					let t;
					t = f == null ? u.getFirstKey?.() : u.getKeyBelow(f), t == null && d && (t = u.getFirstKey?.(f)), l(t);
				}
				break;
			case c() === "vertical" ? "ArrowUp" : "ArrowLeft":
				if (u.getKeyAbove) {
					e.preventDefault();
					let t;
					t = f == null ? u.getLastKey?.() : u.getKeyAbove(f), t == null && d && (t = u.getLastKey?.(f)), l(t);
				}
				break;
			case c() === "vertical" ? "ArrowLeft" : "ArrowUp":
				if (u.getKeyLeftOf) {
					e.preventDefault();
					let t = a() === "rtl", n;
					n = f == null ? t ? u.getFirstKey?.() : u.getLastKey?.() : u.getKeyLeftOf(f), l(n);
				}
				break;
			case c() === "vertical" ? "ArrowRight" : "ArrowDown":
				if (u.getKeyRightOf) {
					e.preventDefault();
					let t = a() === "rtl", n;
					n = f == null ? t ? u.getLastKey?.() : u.getFirstKey?.() : u.getKeyRightOf(f), l(n);
				}
				break;
			case "Home":
				if (u.getFirstKey) {
					e.preventDefault();
					let t = u.getFirstKey(f, eh(e));
					t != null && (i.setFocusedKey(t), eh(e) && e.shiftKey && i.selectionMode() === "multiple" ? i.extendSelection(t) : o && i.replaceSelection(t));
				}
				break;
			case "End":
				if (u.getLastKey) {
					e.preventDefault();
					let t = u.getLastKey(f, eh(e));
					t != null && (i.setFocusedKey(t), eh(e) && e.shiftKey && i.selectionMode() === "multiple" ? i.extendSelection(t) : o && i.replaceSelection(t));
				}
				break;
			case "PageDown":
				u.getKeyPageBelow && f != null && (e.preventDefault(), l(u.getKeyPageBelow(f)));
				break;
			case "PageUp":
				u.getKeyPageAbove && f != null && (e.preventDefault(), l(u.getKeyPageAbove(f)));
				break;
			case "a":
				eh(e) && i.selectionMode() === "multiple" && $(r.disallowSelectAll) !== !0 && (e.preventDefault(), i.selectAll());
				break;
			case "Escape":
				e.defaultPrevented || (e.preventDefault(), $(r.disallowEmptySelection) || i.clearSelection());
				break;
			case "Tab": if (!$(r.allowsTabNavigation)) {
				if (e.shiftKey) n.focus();
				else {
					let e = Cm(n, { tabbable: !0 }), t, r;
					do
						r = e.lastChild(), r && (t = r);
					while (r);
					t && !t.contains(document.activeElement) && om(t);
				}
				break;
			}
		}
	}, u = (e) => {
		let t = $(r.selectionManager), n = $(r.keyboardDelegate), a = $(r.selectOnFocus);
		if (t.isFocused()) {
			e.currentTarget.contains(e.target) || t.setFocused(!1);
			return;
		}
		if (e.currentTarget.contains(e.target)) {
			if (t.setFocused(!0), t.focusedKey() == null) {
				let r = (e) => {
					e != null && (t.setFocusedKey(e), a && t.replaceSelection(e));
				}, i = e.relatedTarget;
				i && e.currentTarget.compareDocumentPosition(i) & Node.DOCUMENT_POSITION_FOLLOWING ? r(t.lastSelectedKey() ?? n.getLastKey?.()) : r(t.firstSelectedKey() ?? n.getFirstKey?.());
			} else if (!$(r.isVirtualized)) {
				let e = i();
				if (e) {
					e.scrollTop = o.top, e.scrollLeft = o.left;
					let n = e.querySelector(`[data-key="${t.focusedKey()}"]`);
					n && (om(n), km(e, n));
				}
			}
		}
	}, d = (e) => {
		let t = $(r.selectionManager);
		e.currentTarget.contains(e.relatedTarget) || t.setFocused(!1);
	}, f = (e) => {
		i() === e.target && e.preventDefault();
	}, p = () => {
		let e = $(r.autoFocus);
		if (!e) return;
		let n = $(r.selectionManager), i = $(r.keyboardDelegate), a;
		e === "first" && (a = i.getFirstKey?.()), e === "last" && (a = i.getLastKey?.());
		let o = n.selectedKeys();
		o.size && (a = o.values().next().value), n.setFocused(!0), n.setFocusedKey(a);
		let s = t();
		s && a == null && !$(r.shouldUseVirtualFocus) && om(s);
	};
	return ae(() => {
		r.deferAutoFocus ? setTimeout(p, 0) : p();
	}), P(ie([
		i,
		() => $(r.isVirtualized),
		() => $(r.selectionManager).focusedKey()
	], (e) => {
		let [t, n, i] = e;
		if (n) i && r.scrollToKey?.(i);
		else if (i && t) {
			let e = t.querySelector(`[data-key="${i}"]`);
			e && km(t, e);
		}
	})), {
		tabIndex: F(() => {
			if (!$(r.shouldUseVirtualFocus)) return $(r.selectionManager).focusedKey() == null ? 0 : -1;
		}),
		onKeyDown: l,
		onMouseDown: f,
		onFocusIn: u,
		onFocusOut: d
	};
}
function ch(e, t) {
	let n = () => $(e.selectionManager), r = () => $(e.key), i = () => $(e.shouldUseVirtualFocus), a = (e) => {
		n().selectionMode() !== "none" && (n().selectionMode() === "single" ? n().isSelected(r()) && !n().disallowEmptySelection() ? n().toggleSelection(r()) : n().replaceSelection(r()) : e?.shiftKey ? n().extendSelection(r()) : n().selectionBehavior() === "toggle" || eh(e) || "pointerType" in e && e.pointerType === "touch" ? n().toggleSelection(r()) : n().replaceSelection(r()));
	}, o = () => n().isSelected(r()), s = () => $(e.disabled) || n().isDisabled(r()), c = () => !s() && n().canSelectItem(r()), l = null, u = (t) => {
		c() && (l = t.pointerType, t.pointerType === "mouse" && t.button === 0 && !$(e.shouldSelectOnPressUp) && a(t));
	}, d = (t) => {
		c() && t.pointerType === "mouse" && t.button === 0 && $(e.shouldSelectOnPressUp) && $(e.allowsDifferentPressOrigin) && a(t);
	}, f = (t) => {
		c() && ($(e.shouldSelectOnPressUp) && !$(e.allowsDifferentPressOrigin) || l !== "mouse") && a(t);
	}, p = (e) => {
		!c() || !["Enter", " "].includes(e.key) || ($m(e) ? n().toggleSelection(r()) : a(e));
	}, m = (e) => {
		s() && e.preventDefault();
	}, h = (e) => {
		let a = t();
		i() || s() || !a || e.target === a && n().setFocusedKey(r());
	}, g = F(() => {
		if (!(i() || s())) return r() === n().focusedKey() ? 0 : -1;
	}), _ = F(() => $(e.virtualized) ? void 0 : r());
	return P(ie([
		t,
		r,
		i,
		() => n().focusedKey(),
		() => n().isFocused()
	], ([t, n, r, i, a]) => {
		t && n === i && a && !r && document.activeElement !== t && (e.focus ? e.focus() : om(t));
	})), {
		isSelected: o,
		isDisabled: s,
		allowsSelection: c,
		tabIndex: g,
		dataKey: _,
		onPointerDown: u,
		onPointerUp: d,
		onClick: f,
		onKeyDown: p,
		onMouseDown: m,
		onFocus: h
	};
}
var lh = class {
	collection;
	state;
	constructor(e, t) {
		this.collection = e, this.state = t;
	}
	selectionMode() {
		return this.state.selectionMode();
	}
	disallowEmptySelection() {
		return this.state.disallowEmptySelection();
	}
	selectionBehavior() {
		return this.state.selectionBehavior();
	}
	setSelectionBehavior(e) {
		this.state.setSelectionBehavior(e);
	}
	isFocused() {
		return this.state.isFocused();
	}
	setFocused(e) {
		this.state.setFocused(e);
	}
	focusedKey() {
		return this.state.focusedKey();
	}
	setFocusedKey(e) {
		(e == null || this.collection().getItem(e)) && this.state.setFocusedKey(e);
	}
	selectedKeys() {
		return this.state.selectedKeys();
	}
	isSelected(e) {
		if (this.state.selectionMode() === "none") return !1;
		let t = this.getKey(e);
		return t == null ? !1 : this.state.selectedKeys().has(t);
	}
	isEmpty() {
		return this.state.selectedKeys().size === 0;
	}
	isSelectAll() {
		if (this.isEmpty()) return !1;
		let e = this.state.selectedKeys();
		return this.getAllSelectableKeys().every((t) => e.has(t));
	}
	firstSelectedKey() {
		let e;
		for (let t of this.state.selectedKeys()) {
			let n = this.collection().getItem(t), r = n?.index != null && e?.index != null && n.index < e.index;
			(!e || r) && (e = n);
		}
		return e?.key;
	}
	lastSelectedKey() {
		let e;
		for (let t of this.state.selectedKeys()) {
			let n = this.collection().getItem(t), r = n?.index != null && e?.index != null && n.index > e.index;
			(!e || r) && (e = n);
		}
		return e?.key;
	}
	extendSelection(e) {
		if (this.selectionMode() === "none") return;
		if (this.selectionMode() === "single") {
			this.replaceSelection(e);
			return;
		}
		let t = this.getKey(e);
		if (t == null) return;
		let n = this.state.selectedKeys(), r = n.anchorKey || t, i = new Zm(n, r, t);
		for (let e of this.getKeyRange(r, n.currentKey || t)) i.delete(e);
		for (let e of this.getKeyRange(t, r)) this.canSelectItem(e) && i.add(e);
		this.state.setSelectedKeys(i);
	}
	getKeyRange(e, t) {
		let n = this.collection().getItem(e), r = this.collection().getItem(t);
		return n && r ? n.index != null && r.index != null && n.index <= r.index ? this.getKeyRangeInternal(e, t) : this.getKeyRangeInternal(t, e) : [];
	}
	getKeyRangeInternal(e, t) {
		let n = [], r = e;
		for (; r != null;) {
			let e = this.collection().getItem(r);
			if (e && e.type === "item" && n.push(r), r === t) return n;
			r = this.collection().getKeyAfter(r);
		}
		return [];
	}
	getKey(e) {
		let t = this.collection().getItem(e);
		return t ? !t || t.type !== "item" ? null : t.key : e;
	}
	toggleSelection(e) {
		if (this.selectionMode() === "none") return;
		if (this.selectionMode() === "single" && !this.isSelected(e)) {
			this.replaceSelection(e);
			return;
		}
		let t = this.getKey(e);
		if (t == null) return;
		let n = new Zm(this.state.selectedKeys());
		n.has(t) ? n.delete(t) : this.canSelectItem(t) && (n.add(t), n.anchorKey = t, n.currentKey = t), !(this.disallowEmptySelection() && n.size === 0) && this.state.setSelectedKeys(n);
	}
	replaceSelection(e) {
		if (this.selectionMode() === "none") return;
		let t = this.getKey(e);
		if (t == null) return;
		let n = this.canSelectItem(t) ? new Zm([t], t, t) : new Zm();
		this.state.setSelectedKeys(n);
	}
	setSelectedKeys(e) {
		if (this.selectionMode() === "none") return;
		let t = new Zm();
		for (let n of e) {
			let e = this.getKey(n);
			if (e != null && (t.add(e), this.selectionMode() === "single")) break;
		}
		this.state.setSelectedKeys(t);
	}
	selectAll() {
		this.selectionMode() === "multiple" && this.state.setSelectedKeys(new Set(this.getAllSelectableKeys()));
	}
	clearSelection() {
		let e = this.state.selectedKeys();
		!this.disallowEmptySelection() && e.size > 0 && this.state.setSelectedKeys(new Zm());
	}
	toggleSelectAll() {
		this.isSelectAll() ? this.clearSelection() : this.selectAll();
	}
	select(e, t) {
		this.selectionMode() !== "none" && (this.selectionMode() === "single" ? this.isSelected(e) && !this.disallowEmptySelection() ? this.toggleSelection(e) : this.replaceSelection(e) : this.selectionBehavior() === "toggle" || t && t.pointerType === "touch" ? this.toggleSelection(e) : this.replaceSelection(e));
	}
	isSelectionEqual(e) {
		if (e === this.state.selectedKeys()) return !0;
		let t = this.selectedKeys();
		if (e.size !== t.size) return !1;
		for (let n of e) if (!t.has(n)) return !1;
		for (let n of t) if (!e.has(n)) return !1;
		return !0;
	}
	canSelectItem(e) {
		if (this.state.selectionMode() === "none") return !1;
		let t = this.collection().getItem(e);
		return t != null && !t.disabled;
	}
	isDisabled(e) {
		let t = this.collection().getItem(e);
		return !t || t.disabled;
	}
	getAllSelectableKeys() {
		let e = [];
		return ((t) => {
			for (; t != null;) {
				if (this.canSelectItem(t)) {
					let n = this.collection().getItem(t);
					if (!n) continue;
					n.type === "item" && e.push(t);
				}
				t = this.collection().getKeyAfter(t);
			}
		})(this.collection().getFirstKey()), e;
	}
}, uh = class {
	keyMap = /* @__PURE__ */ new Map();
	iterable;
	firstKey;
	lastKey;
	constructor(e) {
		this.iterable = e;
		for (let t of e) this.keyMap.set(t.key, t);
		if (this.keyMap.size === 0) return;
		let t, n = 0;
		for (let [e, r] of this.keyMap) t ? (t.nextKey = e, r.prevKey = t.key) : (this.firstKey = e, r.prevKey = void 0), r.type === "item" && (r.index = n++), t = r, t.nextKey = void 0;
		this.lastKey = t.key;
	}
	*[Symbol.iterator]() {
		yield* this.iterable;
	}
	getSize() {
		return this.keyMap.size;
	}
	getKeys() {
		return this.keyMap.keys();
	}
	getKeyBefore(e) {
		return this.keyMap.get(e)?.prevKey;
	}
	getKeyAfter(e) {
		return this.keyMap.get(e)?.nextKey;
	}
	getFirstKey() {
		return this.firstKey;
	}
	getLastKey() {
		return this.lastKey;
	}
	getItem(e) {
		return this.keyMap.get(e);
	}
	at(e) {
		let t = [...this.getKeys()];
		return this.getItem(t[e]);
	}
};
function dh(e) {
	let t = rh(e), n = Nm({
		dataSource: () => $(e.dataSource),
		getKey: () => $(e.getKey),
		getTextValue: () => $(e.getTextValue),
		getDisabled: () => $(e.getDisabled),
		getSectionChildren: () => $(e.getSectionChildren),
		factory: (t) => e.filter ? new uh(e.filter(t)) : new uh(t)
	}, [() => e.filter]), r = new lh(n, t);
	return M(() => {
		let e = t.focusedKey();
		e != null && !n().getItem(e) && t.setFocusedKey(void 0);
	}), {
		collection: n,
		selectionManager: () => r
	};
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/SOM3K36D.jsx
var fh = de();
function ph() {
	return fe(fh);
}
function mh() {
	let e = ph();
	if (e === void 0) throw Error("[kobalte]: `useDomCollectionContext` must be used within a `DomCollectionProvider` component");
	return e;
}
function hh(e, t) {
	return !!(t.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_PRECEDING);
}
function gh(e, t) {
	let n = t.ref();
	if (!n) return -1;
	let r = e.length;
	if (!r) return -1;
	for (; r--;) {
		let t = e[r]?.ref();
		if (t && hh(t, n)) return r + 1;
	}
	return 0;
}
function _h(e) {
	let t = e.map((e, t) => [t, e]), n = !1;
	return t.sort(([e, t], [r, i]) => {
		let a = t.ref(), o = i.ref();
		return a === o || !a || !o ? 0 : hh(a, o) ? (e > r && (n = !0), -1) : (e < r && (n = !0), 1);
	}), n ? t.map(([e, t]) => t) : e;
}
function vh(e, t) {
	let n = _h(e);
	e !== n && t(n);
}
function yh(e) {
	let t = e[0], n = e[e.length - 1]?.ref(), r = t?.ref()?.parentElement;
	for (; r;) {
		if (n && r.contains(n)) return r;
		r = r.parentElement;
	}
	return Gp(r).body;
}
function bh(e, t) {
	P(() => {
		let n = setTimeout(() => {
			vh(e(), t);
		});
		L(() => clearTimeout(n));
	});
}
function xh(e, t) {
	if (typeof IntersectionObserver != "function") {
		bh(e, t);
		return;
	}
	let n = [];
	P(() => {
		let r = () => {
			let r = !!n.length;
			n = e(), r && vh(e(), t);
		}, i = yh(e()), a = new IntersectionObserver(r, { root: i });
		for (let t of e()) {
			let e = t.ref();
			e && a.observe(e);
		}
		L(() => a.disconnect());
	});
}
function Sh(e = {}) {
	let [t, n] = Xm({
		value: () => $(e.items),
		onChange: (t) => e.onItemsChange?.(t)
	});
	xh(t, n);
	let r = (e) => (n((t) => Ip(t, e, gh(t, e))), () => {
		n((t) => {
			let n = t.filter((t) => t.ref() !== e.ref());
			return t.length === n.length ? t : n;
		});
	});
	return { DomCollectionProvider: (e) => R(fh.Provider, {
		value: { registerItem: r },
		get children() {
			return e.children;
		}
	}) };
}
function Ch(e) {
	let t = mh(), n = Tm({ shouldRegisterItem: !0 }, e);
	P(() => {
		n.shouldRegisterItem && L(t.registerItem(n.getItem()));
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/FLVHQV4A.jsx
function wh(e) {
	let [t, n] = B(e, ["as"]);
	if (!t.as) throw Error("[kobalte]: Polymorphic is missing the required `as` prop.");
	return R(Dt, z(n, { get component() {
		return t.as;
	} }));
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/5WXHJDCZ.jsx
var Th = Object.defineProperty, Eh = (e, t) => {
	for (var n in t) Th(e, n, {
		get: t[n],
		enumerable: !0
	});
}, Dh = (e) => typeof e == "function" ? e() : e, Oh = (e) => {
	let t = F(() => {
		let t = Dh(e.element);
		if (t) return getComputedStyle(t);
	}), n = () => t()?.animationName ?? "none", [r, i] = j(Dh(e.show) ? "present" : "hidden"), a = "none";
	return P((r) => {
		let o = Dh(e.show);
		return I(() => {
			if (r === o) return o;
			let e = a, s = n();
			o ? i("present") : s === "none" || t()?.display === "none" ? i("hidden") : i(r === !0 && e !== s ? "hiding" : "hidden");
		}), o;
	}), P(() => {
		let t = Dh(e.element);
		if (!t) return;
		let o = (e) => {
			e.target === t && (a = n());
		}, s = (e) => {
			let a = n().includes(e.animationName);
			e.target === t && a && r() === "hiding" && i("hidden");
		};
		t.addEventListener("animationstart", o), t.addEventListener("animationcancel", s), t.addEventListener("animationend", s), L(() => {
			t.removeEventListener("animationstart", o), t.removeEventListener("animationcancel", s), t.removeEventListener("animationend", s);
		});
	}), {
		present: () => r() === "present" || r() === "hiding",
		state: r,
		setState: i
	};
};
//#endregion
//#region node_modules/.pnpm/@solid-primitives+resize-observer@2.1.5_solid-js@1.9.13/node_modules/@solid-primitives/resize-observer/dist/index.js
function kh(e, t) {
	let n = new ResizeObserver(e);
	return L(n.disconnect.bind(n)), {
		observe: (e) => n.observe(e, t),
		unobserve: n.unobserve.bind(n)
	};
}
function Ah(e, t, n) {
	let r = /* @__PURE__ */ new WeakMap(), { observe: i, unobserve: a } = kh((e) => {
		for (let n of e) {
			let { contentRect: e, target: i } = n, a = Math.round(e.width), o = Math.round(e.height), s = r.get(i);
			(!s || s.width !== a || s.height !== o) && (t(e, i, n), r.set(i, {
				width: a,
				height: o
			}));
		}
	}, n);
	P((t) => {
		let n = bp(Sp($(e)));
		return Tp(n, t, i, a), n;
	}, []);
}
Eh({}, {
	Content: () => Nh,
	Indicator: () => Ph,
	List: () => Fh,
	Root: () => Lh,
	Tabs: () => zh,
	Trigger: () => Rh,
	useTabsContext: () => Mh
});
var jh = de();
function Mh() {
	let e = fe(jh);
	if (e === void 0) throw Error("[kobalte]: `useTabsContext` must be used within a `Tabs` component");
	return e;
}
function Nh(e) {
	let [t, n] = j(), r = Mh(), [i, a] = B(e, [
		"ref",
		"id",
		"value",
		"forceMount"
	]), [o, s] = j(0), c = () => i.id ?? r.generateContentId(i.value), l = () => r.listState().selectedKey() === i.value, { present: u } = Oh({
		show: () => i.forceMount || l(),
		element: () => t() ?? null
	});
	return P(ie([() => t(), () => u()], ([e, t]) => {
		if (e == null || !t) return;
		let n = () => {
			s(Cm(e, { tabbable: !0 }).nextNode() ? void 0 : 0);
		};
		n();
		let r = new MutationObserver(n);
		r.observe(e, {
			subtree: !0,
			childList: !0,
			attributes: !0,
			attributeFilter: ["tabindex", "disabled"]
		}), L(() => {
			r.disconnect();
		});
	})), P(ie([() => i.value, c], ([e, t]) => {
		r.contentIdsMap().set(e, t);
	})), R(H, {
		get when() {
			return u();
		},
		get children() {
			return R(wh, z({
				as: "div",
				ref(e) {
					var t = Fp(n, i.ref);
					typeof t == "function" && t(e);
				},
				get id() {
					return c();
				},
				role: "tabpanel",
				get tabIndex() {
					return o();
				},
				get "aria-labelledby"() {
					return r.triggerIdsMap().get(i.value);
				},
				get "data-orientation"() {
					return r.orientation();
				},
				get "data-selected"() {
					return l() ? "" : void 0;
				}
			}, a));
		}
	});
}
function Ph(e) {
	let t = Mh(), [n, r] = B(e, ["style"]), [i, a] = j({
		width: void 0,
		height: void 0
	}), { direction: o } = Wm(), s = () => {
		let e = t.selectedTab();
		if (e == null) return;
		let n = {
			transform: void 0,
			width: void 0,
			height: void 0
		}, r = o() === "rtl" ? -1 * (e.offsetParent?.offsetWidth - e.offsetWidth - e.offsetLeft) : e.offsetLeft;
		n.transform = t.orientation() === "vertical" ? `translateY(${e.offsetTop}px)` : `translateX(${r}px)`, t.orientation() === "horizontal" ? n.width = `${e.offsetWidth}px` : n.height = `${e.offsetHeight}px`, a(n);
	};
	ae(() => {
		queueMicrotask(() => {
			s();
		});
	}), P(ie([
		t.selectedTab,
		t.orientation,
		o
	], () => {
		s();
	}, { defer: !0 }));
	let [c, l] = j(!1), u = null, d = null;
	return Ah(t.selectedTab, (e, t) => {
		if (d !== t) {
			d = t;
			return;
		}
		l(!0), u && clearTimeout(u), u = setTimeout(() => {
			u = null, l(!1);
		}, 1), s();
	}), R(wh, z({
		as: "div",
		role: "presentation",
		get style() {
			return Pp(i(), n.style);
		},
		get "data-orientation"() {
			return t.orientation();
		},
		get "data-resizing"() {
			return c();
		}
	}, r));
}
function Fh(e) {
	let t, n = Mh(), [r, i] = B(e, [
		"ref",
		"onKeyDown",
		"onMouseDown",
		"onFocusIn",
		"onFocusOut"
	]), { direction: a } = Wm(), o = new _p(() => n.listState().collection(), a, n.orientation), s = sh({
		selectionManager: () => n.listState().selectionManager(),
		keyboardDelegate: () => o,
		selectOnFocus: () => n.activationMode() === "automatic",
		shouldFocusWrap: !1,
		disallowEmptySelection: !0
	}, () => t);
	return P(() => {
		if (t == null) return;
		let e = t.querySelector(`[data-key="${n.listState().selectedKey()}"]`);
		e != null && n.setSelectedTab(e);
	}), R(wh, z({
		as: "div",
		ref(e) {
			var n = Fp((e) => t = e, r.ref);
			typeof n == "function" && n(e);
		},
		role: "tablist",
		get "aria-orientation"() {
			return n.orientation();
		},
		get "data-orientation"() {
			return n.orientation();
		},
		get onKeyDown() {
			return im([r.onKeyDown, s.onKeyDown]);
		},
		get onMouseDown() {
			return im([r.onMouseDown, s.onMouseDown]);
		},
		get onFocusIn() {
			return im([r.onFocusIn, s.onFocusIn]);
		},
		get onFocusOut() {
			return im([r.onFocusOut, s.onFocusOut]);
		}
	}, i));
}
function Ih(e) {
	let [t, n] = Jm({
		value: () => $(e.selectedKey),
		defaultValue: () => $(e.defaultSelectedKey),
		onChange: (t) => e.onSelectionChange?.(t)
	}), r = F(() => {
		let e = t();
		return e == null ? [] : [e];
	}), [, i] = B(e, ["onSelectionChange"]), { collection: a, selectionManager: o } = dh(z(i, {
		selectionMode: "single",
		disallowEmptySelection: !0,
		allowDuplicateSelectionEvents: !0,
		selectedKeys: r,
		onSelectionChange: (r) => {
			let i = r.values().next().value;
			i === t() && e.onSelectionChange?.(i), n(i);
		}
	}));
	return {
		collection: a,
		selectionManager: o,
		selectedKey: t,
		setSelectedKey: n,
		selectedItem: F(() => {
			let e = t();
			return e == null ? void 0 : a().getItem(e);
		})
	};
}
function Lh(e) {
	let [t, n] = B(Tm({
		id: `tabs-${We()}`,
		orientation: "horizontal",
		activationMode: "automatic"
	}, e), [
		"value",
		"defaultValue",
		"onChange",
		"orientation",
		"activationMode",
		"disabled"
	]), [r, i] = j([]), [a, o] = j(), { DomCollectionProvider: s } = Sh({
		items: r,
		onItemsChange: i
	}), c = Ih({
		selectedKey: () => t.value,
		defaultSelectedKey: () => t.defaultValue,
		onSelectionChange: (e) => t.onChange?.(String(e)),
		dataSource: r
	}), l = c.selectedKey();
	P(ie([
		() => c.selectionManager(),
		() => c.collection(),
		() => c.selectedKey()
	], ([e, t, n]) => {
		let r = n;
		if (e.isEmpty() || r == null || !t.getItem(r)) {
			r = t.getFirstKey();
			let n = r == null ? void 0 : t.getItem(r);
			for (; n?.disabled && n.key !== t.getLastKey();) r = t.getKeyAfter(n.key), n = r == null ? void 0 : t.getItem(r);
			n?.disabled && r === t.getLastKey() && (r = t.getFirstKey()), r != null && e.setSelectedKeys([r]);
		}
		(e.focusedKey() == null || !e.isFocused() && r !== l) && e.setFocusedKey(r), l = r;
	}));
	let u = /* @__PURE__ */ new Map(), d = /* @__PURE__ */ new Map(), f = {
		isDisabled: () => t.disabled ?? !1,
		orientation: () => t.orientation,
		activationMode: () => t.activationMode,
		triggerIdsMap: () => u,
		contentIdsMap: () => d,
		listState: () => c,
		selectedTab: a,
		setSelectedTab: o,
		generateTriggerId: (e) => `${n.id}-trigger-${e}`,
		generateContentId: (e) => `${n.id}-content-${e}`
	};
	return R(s, { get children() {
		return R(jh.Provider, {
			value: f,
			get children() {
				return R(wh, z({
					as: "div",
					get "data-orientation"() {
						return f.orientation();
					}
				}, n));
			}
		});
	} });
}
function Rh(e) {
	let t, n = Mh(), [r, i] = B(Tm({ type: "button" }, e), [
		"ref",
		"id",
		"value",
		"disabled",
		"onPointerDown",
		"onPointerUp",
		"onClick",
		"onKeyDown",
		"onMouseDown",
		"onFocus"
	]), a = () => r.id ?? n.generateTriggerId(r.value), o = () => n.listState().selectionManager().focusedKey() === r.value, s = () => r.disabled || n.isDisabled(), c = () => n.contentIdsMap().get(r.value);
	Ch({ getItem: () => ({
		ref: () => t,
		type: "item",
		key: r.value,
		textValue: "",
		disabled: s()
	}) });
	let l = ch({
		key: () => r.value,
		selectionManager: () => n.listState().selectionManager(),
		disabled: s
	}, () => t), u = (e) => {
		tm() && om(e.currentTarget);
	};
	return P(ie([() => r.value, a], ([e, t]) => {
		n.triggerIdsMap().set(e, t);
	})), R(wh, z({
		as: "button",
		ref(e) {
			var n = Fp((e) => t = e, r.ref);
			typeof n == "function" && n(e);
		},
		get id() {
			return a();
		},
		role: "tab",
		get tabIndex() {
			return U(() => !s())() ? l.tabIndex() : void 0;
		},
		get disabled() {
			return s();
		},
		get "aria-selected"() {
			return l.isSelected();
		},
		get "aria-disabled"() {
			return s() || void 0;
		},
		get "aria-controls"() {
			return U(() => !!l.isSelected())() ? c() : void 0;
		},
		get "data-key"() {
			return l.dataKey();
		},
		get "data-orientation"() {
			return n.orientation();
		},
		get "data-selected"() {
			return l.isSelected() ? "" : void 0;
		},
		get "data-highlighted"() {
			return o() ? "" : void 0;
		},
		get "data-disabled"() {
			return s() ? "" : void 0;
		},
		get onPointerDown() {
			return im([r.onPointerDown, l.onPointerDown]);
		},
		get onPointerUp() {
			return im([r.onPointerUp, l.onPointerUp]);
		},
		get onClick() {
			return im([
				r.onClick,
				l.onClick,
				u
			]);
		},
		get onKeyDown() {
			return im([r.onKeyDown, l.onKeyDown]);
		},
		get onMouseDown() {
			return im([r.onMouseDown, l.onMouseDown]);
		},
		get onFocus() {
			return im([r.onFocus, l.onFocus]);
		}
	}, i));
}
var zh = Object.assign(Lh, {
	Content: Nh,
	Indicator: Ph,
	List: Fh,
	Trigger: Rh
});
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/JNCCF6MP.jsx
function Bh(e) {
	return (t) => (e(t), () => e(void 0));
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/XUUROM4M.jsx
var Vh = [
	"id",
	"name",
	"validationState",
	"required",
	"disabled",
	"readOnly"
];
function Hh(e) {
	let t = Tm({ id: `form-control-${We()}` }, e), [n, r] = j(), [i, a] = j(), [o, s] = j(), [c, l] = j();
	return { formControlContext: {
		name: () => $(t.name) ?? $(t.id),
		dataset: F(() => ({
			"data-valid": $(t.validationState) === "valid" ? "" : void 0,
			"data-invalid": $(t.validationState) === "invalid" ? "" : void 0,
			"data-required": $(t.required) ? "" : void 0,
			"data-disabled": $(t.disabled) ? "" : void 0,
			"data-readonly": $(t.readOnly) ? "" : void 0
		})),
		validationState: () => $(t.validationState),
		isRequired: () => $(t.required),
		isDisabled: () => $(t.disabled),
		isReadOnly: () => $(t.readOnly),
		labelId: n,
		fieldId: i,
		descriptionId: o,
		errorMessageId: c,
		getAriaLabelledBy: (e, t, r) => {
			let i = r != null || n() != null;
			return [
				r,
				n(),
				i && t != null ? e : void 0
			].filter(Boolean).join(" ") || void 0;
		},
		getAriaDescribedBy: (e) => [
			o(),
			c(),
			e
		].filter(Boolean).join(" ") || void 0,
		generateId: Vp(() => $(t.id)),
		registerLabel: Bh(r),
		registerField: Bh(a),
		registerDescription: Bh(s),
		registerErrorMessage: Bh(l)
	} };
}
var Uh = de();
function Wh() {
	let e = fe(Uh);
	if (e === void 0) throw Error("[kobalte]: `useFormControlContext` must be used within a `FormControlContext.Provider` component");
	return e;
}
function Gh(e) {
	let t = Wh(), n = Tm({ id: t.generateId("description") }, e);
	return P(() => L(t.registerDescription(n.id))), R(wh, z({ as: "div" }, () => t.dataset(), n));
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/3LKATPLK.jsx
var Kh = /*#__PURE__*/ W("<option>"), qh = /*#__PURE__*/ W("<div aria-hidden=true><input type=text style=font-size:16px><select tabindex=-1><option>");
function Jh(e) {
	let t, [n, r] = B(e, [
		"ref",
		"onChange",
		"collection",
		"selectionManager",
		"isOpen",
		"isMultiple",
		"isVirtualized",
		"focusTrigger"
	]), i = Wh(), [a, o] = j(!1), s = (e) => {
		let t = n.collection.getItem(e);
		return R(H, {
			get when() {
				return t?.type === "item";
			},
			get children() {
				var r = Kh();
				return r.value = e, X(r, () => t?.textValue), N(() => r.selected = n.selectionManager.isSelected(e)), r;
			}
		});
	};
	return P(ie(() => n.selectionManager.selectedKeys(), (e, n) => {
		n && nh(e, n) || (o(!0), t?.dispatchEvent(new Event("input", {
			bubbles: !0,
			cancelable: !0
		})), t?.dispatchEvent(new Event("change", {
			bubbles: !0,
			cancelable: !0
		})));
	}, { defer: !0 })), (() => {
		var e = qh(), c = e.firstChild, l = c.nextSibling;
		l.firstChild, c.addEventListener("focus", () => n.focusTrigger()), l.addEventListener("change", (e) => {
			rm(e, n.onChange), a() || n.selectionManager.setSelectedKeys(/* @__PURE__ */ new Set([e.target.value])), o(!1);
		});
		var u = Fp((e) => t = e, n.ref);
		return typeof u == "function" && ut(u, l), lt(l, z({
			get multiple() {
				return n.isMultiple;
			},
			get name() {
				return i.name();
			},
			get required() {
				return i.isRequired();
			},
			get disabled() {
				return i.isDisabled();
			},
			get size() {
				return n.collection.getSize();
			},
			get value() {
				return n.selectionManager.firstSelectedKey() ?? "";
			}
		}, r), !1, !0), X(l, R(H, {
			get when() {
				return n.isVirtualized;
			},
			get fallback() {
				return R(V, {
					get each() {
						return [...n.collection.getKeys()];
					},
					children: s
				});
			},
			get children() {
				return R(V, {
					get each() {
						return [...n.selectionManager.selectedKeys()];
					},
					children: s
				});
			}
		}), null), N((t) => {
			var r = jm, a = n.selectionManager.isFocused() || n.isOpen ? -1 : 0, o = i.isRequired(), s = i.isDisabled(), l = i.isReadOnly();
			return t.e = ct(e, r, t.e), a !== t.t && K(c, "tabindex", t.t = a), o !== t.a && (c.required = t.a = o), s !== t.o && (c.disabled = t.o = s), l !== t.i && (c.readOnly = t.i = l), t;
		}, {
			e: void 0,
			t: void 0,
			a: void 0,
			o: void 0,
			i: void 0
		}), e;
	})();
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/FINWO3A5.jsx
var Yh = /* @__PURE__ */ new WeakMap();
function Xh(e) {
	let t = Yh.get(e);
	if (t != null) return t;
	t = 0;
	for (let n of e) n.type === "item" && t++;
	return Yh.set(e, t), t;
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/N3GAC5SS.jsx
var Zh = class {
	collection;
	ref;
	collator;
	constructor(e, t, n) {
		this.collection = e, this.ref = t, this.collator = n;
	}
	getKeyBelow(e) {
		let t = this.collection().getKeyAfter(e);
		for (; t != null;) {
			let e = this.collection().getItem(t);
			if (e && e.type === "item" && !e.disabled) return t;
			t = this.collection().getKeyAfter(t);
		}
	}
	getKeyAbove(e) {
		let t = this.collection().getKeyBefore(e);
		for (; t != null;) {
			let e = this.collection().getItem(t);
			if (e && e.type === "item" && !e.disabled) return t;
			t = this.collection().getKeyBefore(t);
		}
	}
	getFirstKey() {
		let e = this.collection().getFirstKey();
		for (; e != null;) {
			let t = this.collection().getItem(e);
			if (t && t.type === "item" && !t.disabled) return e;
			e = this.collection().getKeyAfter(e);
		}
	}
	getLastKey() {
		let e = this.collection().getLastKey();
		for (; e != null;) {
			let t = this.collection().getItem(e);
			if (t && t.type === "item" && !t.disabled) return e;
			e = this.collection().getKeyBefore(e);
		}
	}
	getItem(e) {
		return this.ref?.()?.querySelector(`[data-key="${e}"]`) ?? null;
	}
	getKeyPageAbove(e) {
		let t = this.ref?.(), n = this.getItem(e);
		if (!t || !n) return;
		let r = Math.max(0, n.offsetTop + n.offsetHeight - t.offsetHeight), i = e;
		for (; i && n && n.offsetTop > r;) i = this.getKeyAbove(i), n = i == null ? null : this.getItem(i);
		return i;
	}
	getKeyPageBelow(e) {
		let t = this.ref?.(), n = this.getItem(e);
		if (!t || !n) return;
		let r = Math.min(t.scrollHeight, n.offsetTop - n.offsetHeight + t.offsetHeight), i = e;
		for (; i && n && n.offsetTop < r;) i = this.getKeyBelow(i), n = i == null ? null : this.getItem(i);
		return i;
	}
	getKeyForSearch(e, t) {
		let n = this.collator?.();
		if (!n) return;
		let r = t == null ? this.getFirstKey() : this.getKeyBelow(t);
		for (; r != null;) {
			let t = this.collection().getItem(r);
			if (t) {
				let i = t.textValue.slice(0, e.length);
				if (t.textValue && n.compare(i, e) === 0) return r;
			}
			r = this.getKeyBelow(r);
		}
	}
};
function Qh(e, t, n) {
	let r = Km({
		usage: "search",
		sensitivity: "base"
	});
	return sh({
		selectionManager: () => $(e.selectionManager),
		keyboardDelegate: F(() => $(e.keyboardDelegate) || new Zh(e.collection, t, r)),
		autoFocus: () => $(e.autoFocus),
		deferAutoFocus: () => $(e.deferAutoFocus),
		shouldFocusWrap: () => $(e.shouldFocusWrap),
		disallowEmptySelection: () => $(e.disallowEmptySelection),
		selectOnFocus: () => $(e.selectOnFocus),
		disallowTypeAhead: () => $(e.disallowTypeAhead),
		shouldUseVirtualFocus: () => $(e.shouldUseVirtualFocus),
		allowsTabNavigation: () => $(e.allowsTabNavigation),
		isVirtualized: () => $(e.isVirtualized),
		scrollToKey: (t) => $(e.scrollToKey)?.(t),
		orientation: () => $(e.orientation)
	}, t, n);
}
Eh({}, {
	Item: () => rg,
	ItemDescription: () => ig,
	ItemIndicator: () => ag,
	ItemLabel: () => og,
	Listbox: () => lg,
	Root: () => sg,
	Section: () => cg,
	useListboxContext: () => eg
});
var $h = de();
function eg() {
	let e = fe($h);
	if (e === void 0) throw Error("[kobalte]: `useListboxContext` must be used within a `Listbox` component");
	return e;
}
var tg = de();
function ng() {
	let e = fe(tg);
	if (e === void 0) throw Error("[kobalte]: `useListboxItemContext` must be used within a `Listbox.Item` component");
	return e;
}
function rg(e) {
	let t, n = eg(), [r, i] = B(Tm({ id: `${n.generateId("item")}-${We()}` }, e), [
		"ref",
		"item",
		"aria-label",
		"aria-labelledby",
		"aria-describedby",
		"onPointerMove",
		"onPointerDown",
		"onPointerUp",
		"onClick",
		"onKeyDown",
		"onMouseDown",
		"onFocus"
	]), [a, o] = j(), [s, c] = j(), l = () => n.listState().selectionManager(), u = () => l().focusedKey() === r.item.key, d = ch({
		key: () => r.item.key,
		selectionManager: l,
		shouldSelectOnPressUp: n.shouldSelectOnPressUp,
		allowsDifferentPressOrigin: () => n.shouldSelectOnPressUp() && n.shouldFocusOnHover(),
		shouldUseVirtualFocus: n.shouldUseVirtualFocus,
		disabled: () => r.item.disabled
	}, () => t), f = () => {
		if (l().selectionMode() !== "none") return d.isSelected();
	}, p = F(() => !(Xp() && tm())), m = () => p() ? r["aria-label"] : void 0, h = () => p() ? a() : void 0, g = () => p() ? s() : void 0, _ = () => {
		if (!n.isVirtualized()) return;
		let e = n.listState().collection().getItem(r.item.key)?.index;
		return e == null ? void 0 : e + 1;
	}, v = () => {
		if (n.isVirtualized()) return Xh(n.listState().collection());
	}, y = (e) => {
		rm(e, r.onPointerMove), e.pointerType === "mouse" && !d.isDisabled() && n.shouldFocusOnHover() && (om(e.currentTarget), l().setFocused(!0), l().setFocusedKey(r.item.key));
	}, b = F(() => ({
		"data-disabled": d.isDisabled() ? "" : void 0,
		"data-selected": d.isSelected() ? "" : void 0,
		"data-highlighted": u() ? "" : void 0
	})), x = {
		isSelected: d.isSelected,
		dataset: b,
		generateId: Vp(() => i.id),
		registerLabelId: Bh(o),
		registerDescriptionId: Bh(c)
	};
	return R(tg.Provider, {
		value: x,
		get children() {
			return R(wh, z({
				as: "li",
				ref(e) {
					var n = Fp((e) => t = e, r.ref);
					typeof n == "function" && n(e);
				},
				role: "option",
				get tabIndex() {
					return d.tabIndex();
				},
				get "aria-disabled"() {
					return d.isDisabled();
				},
				get "aria-selected"() {
					return f();
				},
				get "aria-label"() {
					return m();
				},
				get "aria-labelledby"() {
					return h();
				},
				get "aria-describedby"() {
					return g();
				},
				get "aria-posinset"() {
					return _();
				},
				get "aria-setsize"() {
					return v();
				},
				get "data-key"() {
					return d.dataKey();
				},
				get onPointerDown() {
					return im([r.onPointerDown, d.onPointerDown]);
				},
				get onPointerUp() {
					return im([r.onPointerUp, d.onPointerUp]);
				},
				get onClick() {
					return im([r.onClick, d.onClick]);
				},
				get onKeyDown() {
					return im([r.onKeyDown, d.onKeyDown]);
				},
				get onMouseDown() {
					return im([r.onMouseDown, d.onMouseDown]);
				},
				get onFocus() {
					return im([r.onFocus, d.onFocus]);
				},
				onPointerMove: y
			}, b, i));
		}
	});
}
function ig(e) {
	let t = ng(), n = Tm({ id: t.generateId("description") }, e);
	return P(() => L(t.registerDescriptionId(n.id))), R(wh, z({ as: "div" }, () => t.dataset(), n));
}
function ag(e) {
	let t = ng(), [n, r] = B(Tm({ id: t.generateId("indicator") }, e), ["forceMount"]);
	return R(H, {
		get when() {
			return n.forceMount || t.isSelected();
		},
		get children() {
			return R(wh, z({
				as: "div",
				"aria-hidden": "true"
			}, () => t.dataset(), r));
		}
	});
}
function og(e) {
	let t = ng(), n = Tm({ id: t.generateId("label") }, e);
	return P(() => L(t.registerLabelId(n.id))), R(wh, z({ as: "div" }, () => t.dataset(), n));
}
function sg(e) {
	let t, n = Tm({
		id: `listbox-${We()}`,
		selectionMode: "single",
		virtualized: !1
	}, e), [r, i] = B(n, /* @__PURE__ */ "ref.children.renderItem.renderSection.value.defaultValue.onChange.options.optionValue.optionTextValue.optionDisabled.optionGroupChildren.state.keyboardDelegate.autoFocus.selectionMode.shouldFocusWrap.shouldUseVirtualFocus.shouldSelectOnPressUp.shouldFocusOnHover.allowDuplicateSelectionEvents.disallowEmptySelection.selectionBehavior.selectOnFocus.disallowTypeAhead.allowsTabNavigation.virtualized.scrollToItem.scrollRef.onKeyDown.onMouseDown.onFocusIn.onFocusOut".split(".")), a = F(() => r.state ? r.state : dh({
		selectedKeys: () => r.value,
		defaultSelectedKeys: () => r.defaultValue,
		onSelectionChange: r.onChange,
		allowDuplicateSelectionEvents: () => $(r.allowDuplicateSelectionEvents),
		disallowEmptySelection: () => $(r.disallowEmptySelection),
		selectionBehavior: () => $(r.selectionBehavior),
		selectionMode: () => $(r.selectionMode),
		dataSource: () => r.options ?? [],
		getKey: () => r.optionValue,
		getTextValue: () => r.optionTextValue,
		getDisabled: () => r.optionDisabled,
		getSectionChildren: () => r.optionGroupChildren
	})), o = Qh({
		selectionManager: () => a().selectionManager(),
		collection: () => a().collection(),
		autoFocus: () => $(r.autoFocus),
		shouldFocusWrap: () => $(r.shouldFocusWrap),
		keyboardDelegate: () => r.keyboardDelegate,
		disallowEmptySelection: () => $(r.disallowEmptySelection),
		selectOnFocus: () => $(r.selectOnFocus),
		disallowTypeAhead: () => $(r.disallowTypeAhead),
		shouldUseVirtualFocus: () => $(r.shouldUseVirtualFocus),
		allowsTabNavigation: () => $(r.allowsTabNavigation),
		isVirtualized: () => r.virtualized,
		scrollToKey: () => r.scrollToItem
	}, () => t, () => r.scrollRef?.()), s = {
		listState: a,
		generateId: Vp(() => i.id),
		shouldUseVirtualFocus: () => n.shouldUseVirtualFocus,
		shouldSelectOnPressUp: () => n.shouldSelectOnPressUp,
		shouldFocusOnHover: () => n.shouldFocusOnHover,
		isVirtualized: () => r.virtualized
	};
	return R($h.Provider, {
		value: s,
		get children() {
			return R(wh, z({
				as: "ul",
				ref(e) {
					var n = Fp((e) => t = e, r.ref);
					typeof n == "function" && n(e);
				},
				role: "listbox",
				get tabIndex() {
					return o.tabIndex();
				},
				get "aria-multiselectable"() {
					return a().selectionManager().selectionMode() === "multiple" ? !0 : void 0;
				},
				get onKeyDown() {
					return im([r.onKeyDown, o.onKeyDown]);
				},
				get onMouseDown() {
					return im([r.onMouseDown, o.onMouseDown]);
				},
				get onFocusIn() {
					return im([r.onFocusIn, o.onFocusIn]);
				},
				get onFocusOut() {
					return im([r.onFocusOut, o.onFocusOut]);
				}
			}, i, { get children() {
				return R(H, {
					get when() {
						return !r.virtualized;
					},
					get fallback() {
						return r.children?.(a().collection);
					},
					get children() {
						return R(jp, {
							get each() {
								return [...a().collection()];
							},
							by: "key",
							children: (e) => R(Ke, { get children() {
								return [R(qe, {
									get when() {
										return e().type === "section";
									},
									get children() {
										return r.renderSection?.(e());
									}
								}), R(qe, {
									get when() {
										return e().type === "item";
									},
									get children() {
										return r.renderItem?.(e());
									}
								})];
							} })
						});
					}
				});
			} }));
		}
	});
}
function cg(e) {
	return R(wh, z({
		as: "li",
		role: "presentation"
	}, e));
}
var lg = Object.assign(sg, {
	Item: rg,
	ItemDescription: ig,
	ItemIndicator: ag,
	ItemLabel: og,
	Section: cg
}), ug = [
	"top",
	"right",
	"bottom",
	"left"
], dg = Math.min, fg = Math.max, pg = Math.round, mg = Math.floor, hg = (e) => ({
	x: e,
	y: e
}), gg = {
	left: "right",
	right: "left",
	bottom: "top",
	top: "bottom"
};
function _g(e, t, n) {
	return fg(e, dg(t, n));
}
function vg(e, t) {
	return typeof e == "function" ? e(t) : e;
}
function yg(e) {
	return e.split("-")[0];
}
function bg(e) {
	return e.split("-")[1];
}
function xg(e) {
	return e === "x" ? "y" : "x";
}
function Sg(e) {
	return e === "y" ? "height" : "width";
}
function Cg(e) {
	let t = e[0];
	return t === "t" || t === "b" ? "y" : "x";
}
function wg(e) {
	return xg(Cg(e));
}
function Tg(e, t, n) {
	n === void 0 && (n = !1);
	let r = bg(e), i = wg(e), a = Sg(i), o = i === "x" ? r === (n ? "end" : "start") ? "right" : "left" : r === "start" ? "bottom" : "top";
	return t.reference[a] > t.floating[a] && (o = Pg(o)), [o, Pg(o)];
}
function Eg(e) {
	let t = Pg(e);
	return [
		Dg(e),
		t,
		Dg(t)
	];
}
function Dg(e) {
	return e.includes("start") ? e.replace("start", "end") : e.replace("end", "start");
}
var Og = ["left", "right"], kg = ["right", "left"], Ag = ["top", "bottom"], jg = ["bottom", "top"];
function Mg(e, t, n) {
	switch (e) {
		case "top":
		case "bottom": return n ? t ? kg : Og : t ? Og : kg;
		case "left":
		case "right": return t ? Ag : jg;
		default: return [];
	}
}
function Ng(e, t, n, r) {
	let i = bg(e), a = Mg(yg(e), n === "start", r);
	return i && (a = a.map((e) => e + "-" + i), t && (a = a.concat(a.map(Dg)))), a;
}
function Pg(e) {
	let t = yg(e);
	return gg[t] + e.slice(t.length);
}
function Fg(e) {
	return {
		top: 0,
		right: 0,
		bottom: 0,
		left: 0,
		...e
	};
}
function Ig(e) {
	return typeof e == "number" ? {
		top: e,
		right: e,
		bottom: e,
		left: e
	} : Fg(e);
}
function Lg(e) {
	let { x: t, y: n, width: r, height: i } = e;
	return {
		width: r,
		height: i,
		top: n,
		left: t,
		right: t + r,
		bottom: n + i,
		x: t,
		y: n
	};
}
//#endregion
//#region node_modules/.pnpm/@floating-ui+core@1.7.5/node_modules/@floating-ui/core/dist/floating-ui.core.mjs
function Rg(e, t, n) {
	let { reference: r, floating: i } = e, a = Cg(t), o = wg(t), s = Sg(o), c = yg(t), l = a === "y", u = r.x + r.width / 2 - i.width / 2, d = r.y + r.height / 2 - i.height / 2, f = r[s] / 2 - i[s] / 2, p;
	switch (c) {
		case "top":
			p = {
				x: u,
				y: r.y - i.height
			};
			break;
		case "bottom":
			p = {
				x: u,
				y: r.y + r.height
			};
			break;
		case "right":
			p = {
				x: r.x + r.width,
				y: d
			};
			break;
		case "left":
			p = {
				x: r.x - i.width,
				y: d
			};
			break;
		default: p = {
			x: r.x,
			y: r.y
		};
	}
	switch (bg(t)) {
		case "start":
			p[o] -= f * (n && l ? -1 : 1);
			break;
		case "end":
			p[o] += f * (n && l ? -1 : 1);
			break;
	}
	return p;
}
async function zg(e, t) {
	t === void 0 && (t = {});
	let { x: n, y: r, platform: i, rects: a, elements: o, strategy: s } = e, { boundary: c = "clippingAncestors", rootBoundary: l = "viewport", elementContext: u = "floating", altBoundary: d = !1, padding: f = 0 } = vg(t, e), p = Ig(f), m = o[d ? u === "floating" ? "reference" : "floating" : u], h = Lg(await i.getClippingRect({
		element: await (i.isElement == null ? void 0 : i.isElement(m)) ?? !0 ? m : m.contextElement || await (i.getDocumentElement == null ? void 0 : i.getDocumentElement(o.floating)),
		boundary: c,
		rootBoundary: l,
		strategy: s
	})), g = u === "floating" ? {
		x: n,
		y: r,
		width: a.floating.width,
		height: a.floating.height
	} : a.reference, _ = await (i.getOffsetParent == null ? void 0 : i.getOffsetParent(o.floating)), v = await (i.isElement == null ? void 0 : i.isElement(_)) && await (i.getScale == null ? void 0 : i.getScale(_)) || {
		x: 1,
		y: 1
	}, y = Lg(i.convertOffsetParentRelativeRectToViewportRelativeRect ? await i.convertOffsetParentRelativeRectToViewportRelativeRect({
		elements: o,
		rect: g,
		offsetParent: _,
		strategy: s
	}) : g);
	return {
		top: (h.top - y.top + p.top) / v.y,
		bottom: (y.bottom - h.bottom + p.bottom) / v.y,
		left: (h.left - y.left + p.left) / v.x,
		right: (y.right - h.right + p.right) / v.x
	};
}
var Bg = 50, Vg = async (e, t, n) => {
	let { placement: r = "bottom", strategy: i = "absolute", middleware: a = [], platform: o } = n, s = o.detectOverflow ? o : {
		...o,
		detectOverflow: zg
	}, c = await (o.isRTL == null ? void 0 : o.isRTL(t)), l = await o.getElementRects({
		reference: e,
		floating: t,
		strategy: i
	}), { x: u, y: d } = Rg(l, r, c), f = r, p = 0, m = {};
	for (let n = 0; n < a.length; n++) {
		let h = a[n];
		if (!h) continue;
		let { name: g, fn: _ } = h, { x: v, y, data: b, reset: x } = await _({
			x: u,
			y: d,
			initialPlacement: r,
			placement: f,
			strategy: i,
			middlewareData: m,
			rects: l,
			platform: s,
			elements: {
				reference: e,
				floating: t
			}
		});
		u = v ?? u, d = y ?? d, m[g] = {
			...m[g],
			...b
		}, x && p < Bg && (p++, typeof x == "object" && (x.placement && (f = x.placement), x.rects && (l = x.rects === !0 ? await o.getElementRects({
			reference: e,
			floating: t,
			strategy: i
		}) : x.rects), {x: u, y: d} = Rg(l, f, c)), n = -1);
	}
	return {
		x: u,
		y: d,
		placement: f,
		strategy: i,
		middlewareData: m
	};
}, Hg = (e) => ({
	name: "arrow",
	options: e,
	async fn(t) {
		let { x: n, y: r, placement: i, rects: a, platform: o, elements: s, middlewareData: c } = t, { element: l, padding: u = 0 } = vg(e, t) || {};
		if (l == null) return {};
		let d = Ig(u), f = {
			x: n,
			y: r
		}, p = wg(i), m = Sg(p), h = await o.getDimensions(l), g = p === "y", _ = g ? "top" : "left", v = g ? "bottom" : "right", y = g ? "clientHeight" : "clientWidth", b = a.reference[m] + a.reference[p] - f[p] - a.floating[m], x = f[p] - a.reference[p], ee = await (o.getOffsetParent == null ? void 0 : o.getOffsetParent(l)), S = ee ? ee[y] : 0;
		(!S || !await (o.isElement == null ? void 0 : o.isElement(ee))) && (S = s.floating[y] || a.floating[m]);
		let C = b / 2 - x / 2, w = S / 2 - h[m] / 2 - 1, T = dg(d[_], w), E = dg(d[v], w), D = T, O = S - h[m] - E, k = S / 2 - h[m] / 2 + C, te = _g(D, k, O), A = !c.arrow && bg(i) != null && k !== te && a.reference[m] / 2 - (k < D ? T : E) - h[m] / 2 < 0, j = A ? k < D ? k - D : k - O : 0;
		return {
			[p]: f[p] + j,
			data: {
				[p]: te,
				centerOffset: k - te - j,
				...A && { alignmentOffset: j }
			},
			reset: A
		};
	}
}), Ug = function(e) {
	return e === void 0 && (e = {}), {
		name: "flip",
		options: e,
		async fn(t) {
			var n;
			let { placement: r, middlewareData: i, rects: a, initialPlacement: o, platform: s, elements: c } = t, { mainAxis: l = !0, crossAxis: u = !0, fallbackPlacements: d, fallbackStrategy: f = "bestFit", fallbackAxisSideDirection: p = "none", flipAlignment: m = !0, ...h } = vg(e, t);
			if ((n = i.arrow) != null && n.alignmentOffset) return {};
			let g = yg(r), _ = Cg(o), v = yg(o) === o, y = await (s.isRTL == null ? void 0 : s.isRTL(c.floating)), b = d || (v || !m ? [Pg(o)] : Eg(o)), x = p !== "none";
			!d && x && b.push(...Ng(o, m, p, y));
			let ee = [o, ...b], S = await s.detectOverflow(t, h), C = [], w = i.flip?.overflows || [];
			if (l && C.push(S[g]), u) {
				let e = Tg(r, a, y);
				C.push(S[e[0]], S[e[1]]);
			}
			if (w = [...w, {
				placement: r,
				overflows: C
			}], !C.every((e) => e <= 0)) {
				let e = (i.flip?.index || 0) + 1, t = ee[e];
				if (t && (!(u === "alignment" && _ !== Cg(t)) || w.every((e) => Cg(e.placement) === _ ? e.overflows[0] > 0 : !0))) return {
					data: {
						index: e,
						overflows: w
					},
					reset: { placement: t }
				};
				let n = w.filter((e) => e.overflows[0] <= 0).sort((e, t) => e.overflows[1] - t.overflows[1])[0]?.placement;
				if (!n) switch (f) {
					case "bestFit": {
						let e = w.filter((e) => {
							if (x) {
								let t = Cg(e.placement);
								return t === _ || t === "y";
							}
							return !0;
						}).map((e) => [e.placement, e.overflows.filter((e) => e > 0).reduce((e, t) => e + t, 0)]).sort((e, t) => e[1] - t[1])[0]?.[0];
						e && (n = e);
						break;
					}
					case "initialPlacement":
						n = o;
						break;
				}
				if (r !== n) return { reset: { placement: n } };
			}
			return {};
		}
	};
};
function Wg(e, t) {
	return {
		top: e.top - t.height,
		right: e.right - t.width,
		bottom: e.bottom - t.height,
		left: e.left - t.width
	};
}
function Gg(e) {
	return ug.some((t) => e[t] >= 0);
}
var Kg = function(e) {
	return e === void 0 && (e = {}), {
		name: "hide",
		options: e,
		async fn(t) {
			let { rects: n, platform: r } = t, { strategy: i = "referenceHidden", ...a } = vg(e, t);
			switch (i) {
				case "referenceHidden": {
					let e = Wg(await r.detectOverflow(t, {
						...a,
						elementContext: "reference"
					}), n.reference);
					return { data: {
						referenceHiddenOffsets: e,
						referenceHidden: Gg(e)
					} };
				}
				case "escaped": {
					let e = Wg(await r.detectOverflow(t, {
						...a,
						altBoundary: !0
					}), n.floating);
					return { data: {
						escapedOffsets: e,
						escaped: Gg(e)
					} };
				}
				default: return {};
			}
		}
	};
}, qg = /*#__PURE__*/ new Set(["left", "top"]);
async function Jg(e, t) {
	let { placement: n, platform: r, elements: i } = e, a = await (r.isRTL == null ? void 0 : r.isRTL(i.floating)), o = yg(n), s = bg(n), c = Cg(n) === "y", l = qg.has(o) ? -1 : 1, u = a && c ? -1 : 1, d = vg(t, e), { mainAxis: f, crossAxis: p, alignmentAxis: m } = typeof d == "number" ? {
		mainAxis: d,
		crossAxis: 0,
		alignmentAxis: null
	} : {
		mainAxis: d.mainAxis || 0,
		crossAxis: d.crossAxis || 0,
		alignmentAxis: d.alignmentAxis
	};
	return s && typeof m == "number" && (p = s === "end" ? m * -1 : m), c ? {
		x: p * u,
		y: f * l
	} : {
		x: f * l,
		y: p * u
	};
}
var Yg = function(e) {
	return e === void 0 && (e = 0), {
		name: "offset",
		options: e,
		async fn(t) {
			var n;
			let { x: r, y: i, placement: a, middlewareData: o } = t, s = await Jg(t, e);
			return a === o.offset?.placement && (n = o.arrow) != null && n.alignmentOffset ? {} : {
				x: r + s.x,
				y: i + s.y,
				data: {
					...s,
					placement: a
				}
			};
		}
	};
}, Xg = function(e) {
	return e === void 0 && (e = {}), {
		name: "shift",
		options: e,
		async fn(t) {
			let { x: n, y: r, placement: i, platform: a } = t, { mainAxis: o = !0, crossAxis: s = !1, limiter: c = { fn: (e) => {
				let { x: t, y: n } = e;
				return {
					x: t,
					y: n
				};
			} }, ...l } = vg(e, t), u = {
				x: n,
				y: r
			}, d = await a.detectOverflow(t, l), f = Cg(yg(i)), p = xg(f), m = u[p], h = u[f];
			if (o) {
				let e = p === "y" ? "top" : "left", t = p === "y" ? "bottom" : "right", n = m + d[e], r = m - d[t];
				m = _g(n, m, r);
			}
			if (s) {
				let e = f === "y" ? "top" : "left", t = f === "y" ? "bottom" : "right", n = h + d[e], r = h - d[t];
				h = _g(n, h, r);
			}
			let g = c.fn({
				...t,
				[p]: m,
				[f]: h
			});
			return {
				...g,
				data: {
					x: g.x - n,
					y: g.y - r,
					enabled: {
						[p]: o,
						[f]: s
					}
				}
			};
		}
	};
}, Zg = function(e) {
	return e === void 0 && (e = {}), {
		name: "size",
		options: e,
		async fn(t) {
			var n, r;
			let { placement: i, rects: a, platform: o, elements: s } = t, { apply: c = () => {}, ...l } = vg(e, t), u = await o.detectOverflow(t, l), d = yg(i), f = bg(i), p = Cg(i) === "y", { width: m, height: h } = a.floating, g, _;
			d === "top" || d === "bottom" ? (g = d, _ = f === (await (o.isRTL == null ? void 0 : o.isRTL(s.floating)) ? "start" : "end") ? "left" : "right") : (_ = d, g = f === "end" ? "top" : "bottom");
			let v = h - u.top - u.bottom, y = m - u.left - u.right, b = dg(h - u[g], v), x = dg(m - u[_], y), ee = !t.middlewareData.shift, S = b, C = x;
			if ((n = t.middlewareData.shift) != null && n.enabled.x && (C = y), (r = t.middlewareData.shift) != null && r.enabled.y && (S = v), ee && !f) {
				let e = fg(u.left, 0), t = fg(u.right, 0), n = fg(u.top, 0), r = fg(u.bottom, 0);
				p ? C = m - 2 * (e !== 0 || t !== 0 ? e + t : fg(u.left, u.right)) : S = h - 2 * (n !== 0 || r !== 0 ? n + r : fg(u.top, u.bottom));
			}
			await c({
				...t,
				availableWidth: C,
				availableHeight: S
			});
			let w = await o.getDimensions(s.floating);
			return m !== w.width || h !== w.height ? { reset: { rects: !0 } } : {};
		}
	};
};
//#endregion
//#region node_modules/.pnpm/@floating-ui+utils@0.2.11/node_modules/@floating-ui/utils/dist/floating-ui.utils.dom.mjs
function Qg() {
	return typeof window < "u";
}
function $g(e) {
	return n_(e) ? (e.nodeName || "").toLowerCase() : "#document";
}
function e_(e) {
	var t;
	return (e == null || (t = e.ownerDocument) == null ? void 0 : t.defaultView) || window;
}
function t_(e) {
	return ((n_(e) ? e.ownerDocument : e.document) || window.document)?.documentElement;
}
function n_(e) {
	return Qg() ? e instanceof Node || e instanceof e_(e).Node : !1;
}
function r_(e) {
	return Qg() ? e instanceof Element || e instanceof e_(e).Element : !1;
}
function i_(e) {
	return Qg() ? e instanceof HTMLElement || e instanceof e_(e).HTMLElement : !1;
}
function a_(e) {
	return !Qg() || typeof ShadowRoot > "u" ? !1 : e instanceof ShadowRoot || e instanceof e_(e).ShadowRoot;
}
function o_(e) {
	let { overflow: t, overflowX: n, overflowY: r, display: i } = __(e);
	return /auto|scroll|overlay|hidden|clip/.test(t + r + n) && i !== "inline" && i !== "contents";
}
function s_(e) {
	return /^(table|td|th)$/.test($g(e));
}
function c_(e) {
	try {
		if (e.matches(":popover-open")) return !0;
	} catch {}
	try {
		return e.matches(":modal");
	} catch {
		return !1;
	}
}
var l_ = /transform|translate|scale|rotate|perspective|filter/, u_ = /paint|layout|strict|content/, d_ = (e) => !!e && e !== "none", f_;
function p_(e) {
	let t = r_(e) ? __(e) : e;
	return d_(t.transform) || d_(t.translate) || d_(t.scale) || d_(t.rotate) || d_(t.perspective) || !h_() && (d_(t.backdropFilter) || d_(t.filter)) || l_.test(t.willChange || "") || u_.test(t.contain || "");
}
function m_(e) {
	let t = y_(e);
	for (; i_(t) && !g_(t);) {
		if (p_(t)) return t;
		if (c_(t)) return null;
		t = y_(t);
	}
	return null;
}
function h_() {
	return f_ ??= typeof CSS < "u" && CSS.supports && CSS.supports("-webkit-backdrop-filter", "none"), f_;
}
function g_(e) {
	return /^(html|body|#document)$/.test($g(e));
}
function __(e) {
	return e_(e).getComputedStyle(e);
}
function v_(e) {
	return r_(e) ? {
		scrollLeft: e.scrollLeft,
		scrollTop: e.scrollTop
	} : {
		scrollLeft: e.scrollX,
		scrollTop: e.scrollY
	};
}
function y_(e) {
	if ($g(e) === "html") return e;
	let t = e.assignedSlot || e.parentNode || a_(e) && e.host || t_(e);
	return a_(t) ? t.host : t;
}
function b_(e) {
	let t = y_(e);
	return g_(t) ? e.ownerDocument ? e.ownerDocument.body : e.body : i_(t) && o_(t) ? t : b_(t);
}
function x_(e, t, n) {
	t === void 0 && (t = []), n === void 0 && (n = !0);
	let r = b_(e), i = r === e.ownerDocument?.body, a = e_(r);
	if (i) {
		let e = S_(a);
		return t.concat(a, a.visualViewport || [], o_(r) ? r : [], e && n ? x_(e) : []);
	} else return t.concat(r, x_(r, [], n));
}
function S_(e) {
	return e.parent && Object.getPrototypeOf(e.parent) ? e.frameElement : null;
}
//#endregion
//#region node_modules/.pnpm/@floating-ui+dom@1.7.6/node_modules/@floating-ui/dom/dist/floating-ui.dom.mjs
function C_(e) {
	let t = __(e), n = parseFloat(t.width) || 0, r = parseFloat(t.height) || 0, i = i_(e), a = i ? e.offsetWidth : n, o = i ? e.offsetHeight : r, s = pg(n) !== a || pg(r) !== o;
	return s && (n = a, r = o), {
		width: n,
		height: r,
		$: s
	};
}
function w_(e) {
	return r_(e) ? e : e.contextElement;
}
function T_(e) {
	let t = w_(e);
	if (!i_(t)) return hg(1);
	let n = t.getBoundingClientRect(), { width: r, height: i, $: a } = C_(t), o = (a ? pg(n.width) : n.width) / r, s = (a ? pg(n.height) : n.height) / i;
	return (!o || !Number.isFinite(o)) && (o = 1), (!s || !Number.isFinite(s)) && (s = 1), {
		x: o,
		y: s
	};
}
var E_ = /*#__PURE__*/ hg(0);
function D_(e) {
	let t = e_(e);
	return !h_() || !t.visualViewport ? E_ : {
		x: t.visualViewport.offsetLeft,
		y: t.visualViewport.offsetTop
	};
}
function O_(e, t, n) {
	return t === void 0 && (t = !1), !n || t && n !== e_(e) ? !1 : t;
}
function k_(e, t, n, r) {
	t === void 0 && (t = !1), n === void 0 && (n = !1);
	let i = e.getBoundingClientRect(), a = w_(e), o = hg(1);
	t && (r ? r_(r) && (o = T_(r)) : o = T_(e));
	let s = O_(a, n, r) ? D_(a) : hg(0), c = (i.left + s.x) / o.x, l = (i.top + s.y) / o.y, u = i.width / o.x, d = i.height / o.y;
	if (a) {
		let e = e_(a), t = r && r_(r) ? e_(r) : r, n = e, i = S_(n);
		for (; i && r && t !== n;) {
			let e = T_(i), t = i.getBoundingClientRect(), r = __(i), a = t.left + (i.clientLeft + parseFloat(r.paddingLeft)) * e.x, o = t.top + (i.clientTop + parseFloat(r.paddingTop)) * e.y;
			c *= e.x, l *= e.y, u *= e.x, d *= e.y, c += a, l += o, n = e_(i), i = S_(n);
		}
	}
	return Lg({
		width: u,
		height: d,
		x: c,
		y: l
	});
}
function A_(e, t) {
	let n = v_(e).scrollLeft;
	return t ? t.left + n : k_(t_(e)).left + n;
}
function j_(e, t) {
	let n = e.getBoundingClientRect();
	return {
		x: n.left + t.scrollLeft - A_(e, n),
		y: n.top + t.scrollTop
	};
}
function M_(e) {
	let { elements: t, rect: n, offsetParent: r, strategy: i } = e, a = i === "fixed", o = t_(r), s = t ? c_(t.floating) : !1;
	if (r === o || s && a) return n;
	let c = {
		scrollLeft: 0,
		scrollTop: 0
	}, l = hg(1), u = hg(0), d = i_(r);
	if ((d || !d && !a) && (($g(r) !== "body" || o_(o)) && (c = v_(r)), d)) {
		let e = k_(r);
		l = T_(r), u.x = e.x + r.clientLeft, u.y = e.y + r.clientTop;
	}
	let f = o && !d && !a ? j_(o, c) : hg(0);
	return {
		width: n.width * l.x,
		height: n.height * l.y,
		x: n.x * l.x - c.scrollLeft * l.x + u.x + f.x,
		y: n.y * l.y - c.scrollTop * l.y + u.y + f.y
	};
}
function N_(e) {
	return Array.from(e.getClientRects());
}
function P_(e) {
	let t = t_(e), n = v_(e), r = e.ownerDocument.body, i = fg(t.scrollWidth, t.clientWidth, r.scrollWidth, r.clientWidth), a = fg(t.scrollHeight, t.clientHeight, r.scrollHeight, r.clientHeight), o = -n.scrollLeft + A_(e), s = -n.scrollTop;
	return __(r).direction === "rtl" && (o += fg(t.clientWidth, r.clientWidth) - i), {
		width: i,
		height: a,
		x: o,
		y: s
	};
}
var F_ = 25;
function I_(e, t) {
	let n = e_(e), r = t_(e), i = n.visualViewport, a = r.clientWidth, o = r.clientHeight, s = 0, c = 0;
	if (i) {
		a = i.width, o = i.height;
		let e = h_();
		(!e || e && t === "fixed") && (s = i.offsetLeft, c = i.offsetTop);
	}
	let l = A_(r);
	if (l <= 0) {
		let e = r.ownerDocument, t = e.body, n = getComputedStyle(t), i = e.compatMode === "CSS1Compat" && parseFloat(n.marginLeft) + parseFloat(n.marginRight) || 0, o = Math.abs(r.clientWidth - t.clientWidth - i);
		o <= F_ && (a -= o);
	} else l <= F_ && (a += l);
	return {
		width: a,
		height: o,
		x: s,
		y: c
	};
}
function L_(e, t) {
	let n = k_(e, !0, t === "fixed"), r = n.top + e.clientTop, i = n.left + e.clientLeft, a = i_(e) ? T_(e) : hg(1);
	return {
		width: e.clientWidth * a.x,
		height: e.clientHeight * a.y,
		x: i * a.x,
		y: r * a.y
	};
}
function R_(e, t, n) {
	let r;
	if (t === "viewport") r = I_(e, n);
	else if (t === "document") r = P_(t_(e));
	else if (r_(t)) r = L_(t, n);
	else {
		let n = D_(e);
		r = {
			x: t.x - n.x,
			y: t.y - n.y,
			width: t.width,
			height: t.height
		};
	}
	return Lg(r);
}
function z_(e, t) {
	let n = y_(e);
	return n === t || !r_(n) || g_(n) ? !1 : __(n).position === "fixed" || z_(n, t);
}
function B_(e, t) {
	let n = t.get(e);
	if (n) return n;
	let r = x_(e, [], !1).filter((e) => r_(e) && $g(e) !== "body"), i = null, a = __(e).position === "fixed", o = a ? y_(e) : e;
	for (; r_(o) && !g_(o);) {
		let t = __(o), n = p_(o);
		!n && t.position === "fixed" && (i = null), (a ? !n && !i : !n && t.position === "static" && i && (i.position === "absolute" || i.position === "fixed") || o_(o) && !n && z_(e, o)) ? r = r.filter((e) => e !== o) : i = t, o = y_(o);
	}
	return t.set(e, r), r;
}
function V_(e) {
	let { element: t, boundary: n, rootBoundary: r, strategy: i } = e, a = [...n === "clippingAncestors" ? c_(t) ? [] : B_(t, this._c) : [].concat(n), r], o = R_(t, a[0], i), s = o.top, c = o.right, l = o.bottom, u = o.left;
	for (let e = 1; e < a.length; e++) {
		let n = R_(t, a[e], i);
		s = fg(n.top, s), c = dg(n.right, c), l = dg(n.bottom, l), u = fg(n.left, u);
	}
	return {
		width: c - u,
		height: l - s,
		x: u,
		y: s
	};
}
function H_(e) {
	let { width: t, height: n } = C_(e);
	return {
		width: t,
		height: n
	};
}
function U_(e, t, n) {
	let r = i_(t), i = t_(t), a = n === "fixed", o = k_(e, !0, a, t), s = {
		scrollLeft: 0,
		scrollTop: 0
	}, c = hg(0);
	function l() {
		c.x = A_(i);
	}
	if (r || !r && !a) if (($g(t) !== "body" || o_(i)) && (s = v_(t)), r) {
		let e = k_(t, !0, a, t);
		c.x = e.x + t.clientLeft, c.y = e.y + t.clientTop;
	} else i && l();
	a && !r && i && l();
	let u = i && !r && !a ? j_(i, s) : hg(0);
	return {
		x: o.left + s.scrollLeft - c.x - u.x,
		y: o.top + s.scrollTop - c.y - u.y,
		width: o.width,
		height: o.height
	};
}
function W_(e) {
	return __(e).position === "static";
}
function G_(e, t) {
	if (!i_(e) || __(e).position === "fixed") return null;
	if (t) return t(e);
	let n = e.offsetParent;
	return t_(e) === n && (n = n.ownerDocument.body), n;
}
function K_(e, t) {
	let n = e_(e);
	if (c_(e)) return n;
	if (!i_(e)) {
		let t = y_(e);
		for (; t && !g_(t);) {
			if (r_(t) && !W_(t)) return t;
			t = y_(t);
		}
		return n;
	}
	let r = G_(e, t);
	for (; r && s_(r) && W_(r);) r = G_(r, t);
	return r && g_(r) && W_(r) && !p_(r) ? n : r || m_(e) || n;
}
var q_ = async function(e) {
	let t = this.getOffsetParent || K_, n = this.getDimensions, r = await n(e.floating);
	return {
		reference: U_(e.reference, await t(e.floating), e.strategy),
		floating: {
			x: 0,
			y: 0,
			width: r.width,
			height: r.height
		}
	};
};
function J_(e) {
	return __(e).direction === "rtl";
}
var Y_ = {
	convertOffsetParentRelativeRectToViewportRelativeRect: M_,
	getDocumentElement: t_,
	getClippingRect: V_,
	getOffsetParent: K_,
	getElementRects: q_,
	getClientRects: N_,
	getDimensions: H_,
	getScale: T_,
	isElement: r_,
	isRTL: J_
};
function X_(e, t) {
	return e.x === t.x && e.y === t.y && e.width === t.width && e.height === t.height;
}
function Z_(e, t) {
	let n = null, r, i = t_(e);
	function a() {
		var e;
		clearTimeout(r), (e = n) == null || e.disconnect(), n = null;
	}
	function o(s, c) {
		s === void 0 && (s = !1), c === void 0 && (c = 1), a();
		let l = e.getBoundingClientRect(), { left: u, top: d, width: f, height: p } = l;
		if (s || t(), !f || !p) return;
		let m = mg(d), h = mg(i.clientWidth - (u + f)), g = mg(i.clientHeight - (d + p)), _ = mg(u), v = {
			rootMargin: -m + "px " + -h + "px " + -g + "px " + -_ + "px",
			threshold: fg(0, dg(1, c)) || 1
		}, y = !0;
		function b(t) {
			let n = t[0].intersectionRatio;
			if (n !== c) {
				if (!y) return o();
				n ? o(!1, n) : r = setTimeout(() => {
					o(!1, 1e-7);
				}, 1e3);
			}
			n === 1 && !X_(l, e.getBoundingClientRect()) && o(), y = !1;
		}
		try {
			n = new IntersectionObserver(b, {
				...v,
				root: i.ownerDocument
			});
		} catch {
			n = new IntersectionObserver(b, v);
		}
		n.observe(e);
	}
	return o(!0), a;
}
function Q_(e, t, n, r) {
	r === void 0 && (r = {});
	let { ancestorScroll: i = !0, ancestorResize: a = !0, elementResize: o = typeof ResizeObserver == "function", layoutShift: s = typeof IntersectionObserver == "function", animationFrame: c = !1 } = r, l = w_(e), u = i || a ? [...l ? x_(l) : [], ...t ? x_(t) : []] : [];
	u.forEach((e) => {
		i && e.addEventListener("scroll", n, { passive: !0 }), a && e.addEventListener("resize", n);
	});
	let d = l && s ? Z_(l, n) : null, f = -1, p = null;
	o && (p = new ResizeObserver((e) => {
		let [r] = e;
		r && r.target === l && p && t && (p.unobserve(t), cancelAnimationFrame(f), f = requestAnimationFrame(() => {
			var e;
			(e = p) == null || e.observe(t);
		})), n();
	}), l && !c && p.observe(l), t && p.observe(t));
	let m, h = c ? k_(e) : null;
	c && g();
	function g() {
		let t = k_(e);
		h && !X_(h, t) && n(), h = t, m = requestAnimationFrame(g);
	}
	return n(), () => {
		var e;
		u.forEach((e) => {
			i && e.removeEventListener("scroll", n), a && e.removeEventListener("resize", n);
		}), d?.(), (e = p) == null || e.disconnect(), p = null, c && cancelAnimationFrame(m);
	};
}
var $_ = Yg, ev = Xg, tv = Ug, nv = Zg, rv = Kg, iv = Hg, av = (e, t, n) => {
	let r = /* @__PURE__ */ new Map(), i = {
		platform: Y_,
		...n
	}, a = {
		...i.platform,
		_c: r
	};
	return Vg(e, t, {
		...i,
		platform: a
	});
}, ov = /*#__PURE__*/ W("<svg display=block viewBox=\"0 0 30 30\"style=transform:scale(1.02)><g><path fill=none d=M23,27.8c1.1,1.2,3.4,2.2,5,2.2h2H0h2c1.7,0,3.9-1,5-2.2l6.6-7.2c0.7-0.8,2-0.8,2.7,0L23,27.8L23,27.8z></path><path stroke=none d=M23,27.8c1.1,1.2,3.4,2.2,5,2.2h2H0h2c1.7,0,3.9-1,5-2.2l6.6-7.2c0.7-0.8,2-0.8,2.7,0L23,27.8L23,27.8z>"), sv = de();
function cv() {
	let e = fe(sv);
	if (e === void 0) throw Error("[kobalte]: `usePopperContext` must be used within a `Popper` component");
	return e;
}
var lv = 30, uv = lv / 2, dv = {
	top: 180,
	right: -90,
	bottom: 0,
	left: 90
};
function fv(e) {
	let t = cv(), [n, r] = B(Tm({ size: lv }, e), [
		"ref",
		"style",
		"size"
	]), i = () => t.currentPlacement().split("-")[0], a = pv(t.contentRef), o = () => a()?.getPropertyValue("background-color") || "none", s = () => a()?.getPropertyValue(`border-${i()}-color`) || "none", c = () => a()?.getPropertyValue(`border-${i()}-width`) || "0px", l = () => Number.parseInt(c()) * 2 * (lv / n.size), u = () => `rotate(${dv[i()]} ${uv} ${uv}) translate(0 2)`;
	return R(wh, z({
		as: "div",
		ref(e) {
			var r = Fp(t.setArrowRef, n.ref);
			typeof r == "function" && r(e);
		},
		"aria-hidden": "true",
		get style() {
			return Pp({
				position: "absolute",
				"font-size": `${n.size}px`,
				width: "1em",
				height: "1em",
				"pointer-events": "none",
				fill: o(),
				stroke: s(),
				"stroke-width": l()
			}, n.style);
		}
	}, r, { get children() {
		var e = ov(), t = e.firstChild;
		return t.firstChild.nextSibling, N(() => K(t, "transform", u())), e;
	} }));
}
function pv(e) {
	let [t, n] = j();
	return P(() => {
		let t = e();
		t && n(Wp(t).getComputedStyle(t));
	}), t;
}
function mv(e) {
	let t = cv(), [n, r] = B(e, ["ref", "style"]);
	return R(wh, z({
		as: "div",
		ref(e) {
			var r = Fp(t.setPositionerRef, n.ref);
			typeof r == "function" && r(e);
		},
		"data-popper-positioner": "",
		get style() {
			return Pp({
				position: "absolute",
				top: 0,
				left: 0,
				"min-width": "max-content"
			}, n.style);
		}
	}, r));
}
function hv(e) {
	let { x: t = 0, y: n = 0, width: r = 0, height: i = 0 } = e ?? {};
	if (typeof DOMRect == "function") return new DOMRect(t, n, r, i);
	let a = {
		x: t,
		y: n,
		width: r,
		height: i,
		top: n,
		right: t + r,
		bottom: n + i,
		left: t
	};
	return {
		...a,
		toJSON: () => a
	};
}
function gv(e, t) {
	return {
		contextElement: e,
		getBoundingClientRect: () => {
			let n = t(e);
			return n ? hv(n) : e ? e.getBoundingClientRect() : hv();
		}
	};
}
function _v(e) {
	return /^(?:top|bottom|left|right)(?:-(?:start|end))?$/.test(e);
}
var vv = {
	top: "bottom",
	right: "left",
	bottom: "top",
	left: "right"
};
function yv(e, t) {
	let [n, r] = e.split("-"), i = vv[n];
	return r ? n === "left" || n === "right" ? `${i} ${r === "start" ? "top" : "bottom"}` : r === "start" ? `${i} ${t === "rtl" ? "right" : "left"}` : `${i} ${t === "rtl" ? "left" : "right"}` : `${i} center`;
}
function bv(e) {
	let t = Tm({
		getAnchorRect: (e) => e?.getBoundingClientRect(),
		placement: "bottom",
		gutter: 0,
		shift: 0,
		flip: !0,
		slide: !0,
		overlap: !1,
		sameWidth: !1,
		fitViewport: !1,
		hideWhenDetached: !1,
		detachedPadding: 0,
		arrowPadding: 4,
		overflowPadding: 8
	}, e), [n, r] = j(), [i, a] = j(), [o, s] = j(t.placement), c = () => gv(t.anchorRef?.(), t.getAnchorRect), { direction: l } = Wm();
	async function u() {
		let e = c(), r = n(), a = i();
		if (!e || !r) return;
		let o = (a?.clientHeight || 0) / 2, u = typeof t.gutter == "number" ? t.gutter + o : t.gutter ?? o;
		r.style.setProperty("--kb-popper-content-overflow-padding", `${t.overflowPadding}px`), e.getBoundingClientRect();
		let d = [$_(({ placement: e }) => ({
			mainAxis: u,
			crossAxis: e.split("-")[1] ? void 0 : t.shift,
			alignmentAxis: t.shift
		}))];
		if (t.flip !== !1) {
			let e = typeof t.flip == "string" ? t.flip.split(" ") : void 0;
			if (e !== void 0 && !e.every(_v)) throw Error("`flip` expects a spaced-delimited list of placements");
			d.push(tv({
				padding: t.overflowPadding,
				fallbackPlacements: e
			}));
		}
		(t.slide || t.overlap) && d.push(ev({
			mainAxis: t.slide,
			crossAxis: t.overlap,
			padding: t.overflowPadding
		})), d.push(nv({
			padding: t.overflowPadding,
			apply({ availableWidth: e, availableHeight: n, rects: i }) {
				let a = Math.round(i.reference.width);
				e = Math.floor(e), n = Math.floor(n), r.style.setProperty("--kb-popper-anchor-width", `${a}px`), r.style.setProperty("--kb-popper-content-available-width", `${e}px`), r.style.setProperty("--kb-popper-content-available-height", `${n}px`), t.sameWidth && (r.style.width = `${a}px`), t.fitViewport && (r.style.maxWidth = `${e}px`, r.style.maxHeight = `${n}px`);
			}
		})), t.hideWhenDetached && d.push(rv({ padding: t.detachedPadding })), a && d.push(iv({
			element: a,
			padding: t.arrowPadding
		}));
		let f = await av(e, r, {
			placement: t.placement,
			strategy: "absolute",
			middleware: d,
			platform: {
				...Y_,
				isRTL: () => l() === "rtl"
			}
		});
		if (s(f.placement), t.onCurrentPlacementChange?.(f.placement), !r) return;
		r.style.setProperty("--kb-popper-content-transform-origin", yv(f.placement, l()));
		let p = Math.round(f.x), m = Math.round(f.y), h;
		if (t.hideWhenDetached && (h = f.middlewareData.hide?.referenceHidden ? "hidden" : "visible"), Object.assign(r.style, {
			top: "0",
			left: "0",
			transform: `translate3d(${p}px, ${m}px, 0)`,
			visibility: h
		}), a && f.middlewareData.arrow) {
			let { x: e, y: t } = f.middlewareData.arrow, n = f.placement.split("-")[0];
			Object.assign(a.style, {
				left: e == null ? "" : `${e}px`,
				top: t == null ? "" : `${t}px`,
				[n]: "100%"
			});
		}
	}
	P(() => {
		let e = c(), t = n();
		!e || !t || L(Q_(e, t, u, { elementResize: typeof ResizeObserver == "function" }));
	}), P(() => {
		let e = n(), r = t.contentRef?.();
		!e || !r || queueMicrotask(() => {
			e.style.zIndex = getComputedStyle(r).zIndex;
		});
	});
	let d = {
		currentPlacement: o,
		contentRef: () => t.contentRef?.(),
		setPositionerRef: r,
		setArrowRef: a
	};
	return R(sv.Provider, {
		value: d,
		get children() {
			return t.children;
		}
	});
}
var xv = Object.assign(bv, {
	Arrow: fv,
	Context: sv,
	usePopperContext: cv,
	Positioner: mv
}), Sv = "data-kb-top-layer", Cv, wv = !1, Tv = [];
function Ev(e) {
	return Tv.findIndex((t) => t.node === e);
}
function Dv(e) {
	return Tv[Ev(e)];
}
function Ov(e) {
	return Tv[Tv.length - 1].node === e;
}
function kv() {
	return Tv.filter((e) => e.isPointerBlocking);
}
function Av() {
	return [...kv()].slice(-1)[0];
}
function jv() {
	return kv().length > 0;
}
function Mv(e) {
	let t = Ev(Av()?.node);
	return Ev(e) < t;
}
function Nv(e) {
	Tv.push(e);
}
function Pv(e) {
	let t = Ev(e);
	t < 0 || Tv.splice(t, 1);
}
function Fv() {
	for (let { node: e } of Tv) e.style.pointerEvents = Mv(e) ? "none" : "auto";
}
function Iv(e) {
	if (jv() && !wv) {
		let t = Gp(e);
		Cv = document.body.style.pointerEvents, t.body.style.pointerEvents = "none", wv = !0;
	}
}
function Lv(e) {
	if (jv()) return;
	let t = Gp(e);
	t.body.style.pointerEvents = Cv, t.body.style.length === 0 && t.body.removeAttribute("style"), wv = !1;
}
var Rv = {
	layers: Tv,
	isTopMostLayer: Ov,
	hasPointerBlockingLayer: jv,
	isBelowPointerBlockingLayer: Mv,
	addLayer: Nv,
	removeLayer: Pv,
	indexOf: Ev,
	find: Dv,
	assignPointerEventToLayers: Fv,
	disableBodyPointerEvents: Iv,
	restoreBodyPointerEvents: Lv
}, zv = "focusScope.autoFocusOnMount", Bv = "focusScope.autoFocusOnUnmount", Vv = {
	bubbles: !1,
	cancelable: !0
}, Hv = {
	stack: [],
	active() {
		return this.stack[0];
	},
	add(e) {
		e !== this.active() && this.active()?.pause(), this.stack = Lp(this.stack, e), this.stack.unshift(e);
	},
	remove(e) {
		this.stack = Lp(this.stack, e), this.active()?.resume();
	}
};
function Uv(e, t) {
	let [n, r] = j(!1), i = {
		pause() {
			r(!0);
		},
		resume() {
			r(!1);
		}
	}, a = null, o = (t) => e.onMountAutoFocus?.(t), s = (t) => e.onUnmountAutoFocus?.(t), c = () => Gp(t()), l = () => {
		let e = c().createElement("span");
		return e.setAttribute("data-focus-trap", ""), e.tabIndex = 0, Object.assign(e.style, jm), e;
	}, u = () => {
		let e = t();
		return e ? hm(e, !0).filter((e) => !e.hasAttribute("data-focus-trap")) : [];
	}, d = () => {
		let e = u();
		return e.length > 0 ? e[0] : null;
	}, f = () => {
		let e = u();
		return e.length > 0 ? e[e.length - 1] : null;
	}, p = () => {
		let e = t();
		if (!e) return !1;
		let n = Up(e);
		return !n || Hp(e, n) ? !1 : _m(n);
	};
	P(() => {
		let e = t();
		if (!e) return;
		Hv.add(i);
		let n = Up(e);
		if (!Hp(e, n)) {
			let t = new CustomEvent(zv, Vv);
			e.addEventListener(zv, o), e.dispatchEvent(t), t.defaultPrevented || setTimeout(() => {
				om(d()), Up(e) === n && om(e);
			}, 0);
		}
		L(() => {
			e.removeEventListener(zv, o), setTimeout(() => {
				let t = new CustomEvent(Bv, Vv);
				p() && t.preventDefault(), e.addEventListener(Bv, s), e.dispatchEvent(t), t.defaultPrevented || om(n ?? c().body), e.removeEventListener(Bv, s), Hv.remove(i);
			}, 0);
		});
	}), P(() => {
		let r = t();
		if (!r || !$(e.trapFocus) || n()) return;
		let i = (e) => {
			let t = e.target;
			t?.closest("[data-kb-top-layer]") || (Hp(r, t) ? a = t : om(a));
		}, o = (e) => {
			let t = e.relatedTarget ?? Up(r);
			t?.closest("[data-kb-top-layer]") || Hp(r, t) || om(a);
		};
		c().addEventListener("focusin", i), c().addEventListener("focusout", o), L(() => {
			c().removeEventListener("focusin", i), c().removeEventListener("focusout", o);
		});
	}), P(() => {
		let r = t();
		if (!r || !$(e.trapFocus) || n()) return;
		let i = l();
		r.insertAdjacentElement("afterbegin", i);
		let a = l();
		r.insertAdjacentElement("beforeend", a);
		function o(e) {
			let t = d(), n = f();
			e.relatedTarget === t ? om(n) : om(t);
		}
		i.addEventListener("focusin", o), a.addEventListener("focusin", o);
		let s = new MutationObserver((e) => {
			for (let t of e) t.previousSibling === a && (a.remove(), r.insertAdjacentElement("beforeend", a)), t.nextSibling === i && (i.remove(), r.insertAdjacentElement("afterbegin", i));
		});
		s.observe(r, {
			childList: !0,
			subtree: !1
		}), L(() => {
			i.removeEventListener("focusin", o), a.removeEventListener("focusin", o), i.remove(), a.remove(), s.disconnect();
		});
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/JHMNWOLY.jsx
var Wv = 7e3, Gv = null, Kv = "data-live-announcer";
function qv(e, t = "assertive", n = Wv) {
	Gv ||= new Jv(), Gv.announce(e, t, n);
}
var Jv = class {
	node;
	assertiveLog;
	politeLog;
	constructor() {
		this.node = document.createElement("div"), this.node.dataset.liveAnnouncer = "true", Object.assign(this.node.style, jm), this.assertiveLog = this.createLog("assertive"), this.node.appendChild(this.assertiveLog), this.politeLog = this.createLog("polite"), this.node.appendChild(this.politeLog), document.body.prepend(this.node);
	}
	createLog(e) {
		let t = document.createElement("div");
		return t.setAttribute("role", "log"), t.setAttribute("aria-live", e), t.setAttribute("aria-relevant", "additions"), t;
	}
	destroy() {
		this.node &&= (document.body.removeChild(this.node), null);
	}
	announce(e, t = "assertive", n = Wv) {
		if (!this.node) return;
		let r = document.createElement("div");
		r.textContent = e, t === "assertive" ? this.assertiveLog.appendChild(r) : this.politeLog.appendChild(r), e !== "" && setTimeout(() => {
			r.remove();
		}, n);
	}
	clear(e) {
		this.node && ((!e || e === "assertive") && (this.assertiveLog.innerHTML = ""), (!e || e === "polite") && (this.politeLog.innerHTML = ""));
	}
};
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/FBCYWU27.jsx
function Yv(e) {
	P(() => {
		$(e.isDisabled) || L(Qv($(e.targets), $(e.root)));
	});
}
var Xv = /* @__PURE__ */ new WeakMap(), Zv = [];
function Qv(e, t = document.body) {
	let n = new Set(e), r = /* @__PURE__ */ new Set(), i = (e) => {
		for (let t of e.querySelectorAll(`[${Kv}], [${Sv}]`)) n.add(t);
		let t = (e) => {
			if (n.has(e) || e.parentElement && r.has(e.parentElement) && e.parentElement.getAttribute("role") !== "row") return NodeFilter.FILTER_REJECT;
			for (let t of n) if (e.contains(t)) return NodeFilter.FILTER_SKIP;
			return NodeFilter.FILTER_ACCEPT;
		}, i = document.createTreeWalker(e, NodeFilter.SHOW_ELEMENT, { acceptNode: t }), o = t(e);
		if (o === NodeFilter.FILTER_ACCEPT && a(e), o !== NodeFilter.FILTER_REJECT) {
			let e = i.nextNode();
			for (; e != null;) a(e), e = i.nextNode();
		}
	}, a = (e) => {
		let t = Xv.get(e) ?? 0;
		e.getAttribute("aria-hidden") === "true" && t === 0 || (t === 0 && e.setAttribute("aria-hidden", "true"), r.add(e), Xv.set(e, t + 1));
	};
	Zv.length && Zv[Zv.length - 1].disconnect(), i(t);
	let o = new MutationObserver((e) => {
		for (let t of e) if (!(t.type !== "childList" || t.addedNodes.length === 0) && ![...n, ...r].some((e) => e.contains(t.target))) {
			for (let e of t.removedNodes) e instanceof Element && (n.delete(e), r.delete(e));
			for (let e of t.addedNodes) (e instanceof HTMLElement || e instanceof SVGElement) && (e.dataset.liveAnnouncer === "true" || e.dataset.reactAriaTopLayer === "true") ? n.add(e) : e instanceof Element && i(e);
		}
	});
	o.observe(t, {
		childList: !0,
		subtree: !0
	});
	let s = {
		observe() {
			o.observe(t, {
				childList: !0,
				subtree: !0
			});
		},
		disconnect() {
			o.disconnect();
		}
	};
	return Zv.push(s), () => {
		o.disconnect();
		for (let e of r) {
			let t = Xv.get(e);
			if (t == null) return;
			t === 1 ? (e.removeAttribute("aria-hidden"), Xv.delete(e)) : Xv.set(e, t - 1);
		}
		s === Zv[Zv.length - 1] ? (Zv.pop(), Zv.length && Zv[Zv.length - 1].observe()) : Zv.splice(Zv.indexOf(s), 1);
	};
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/MGQGUY64.jsx
var $v = "interactOutside.pointerDownOutside", ey = "interactOutside.focusOutside";
function ty(e, t) {
	let n, r = wm, i = () => Gp(t()), a = (t) => e.onPointerDownOutside?.(t), o = (t) => e.onFocusOutside?.(t), s = (t) => e.onInteractOutside?.(t), c = (n) => {
		let r = n.target;
		return !(r instanceof Element) || r.closest("[data-kb-top-layer]") || !Hp(i(), r) || Hp(t(), r) ? !1 : !e.shouldExcludeElement?.(r);
	}, l = (e) => {
		function n() {
			let n = t(), r = e.target;
			if (!n || !r || !c(e)) return;
			let i = im([a, s]);
			r.addEventListener($v, i, { once: !0 });
			let o = new CustomEvent($v, {
				bubbles: !1,
				cancelable: !0,
				detail: {
					originalEvent: e,
					isContextMenu: e.button === 2 || am(e) && e.button === 0
				}
			});
			r.dispatchEvent(o);
		}
		e.pointerType === "touch" ? (i().removeEventListener("click", n), r = n, i().addEventListener("click", n, { once: !0 })) : n();
	}, u = (e) => {
		let n = t(), r = e.target;
		if (!n || !r || !c(e)) return;
		let i = im([o, s]);
		r.addEventListener(ey, i, { once: !0 });
		let a = new CustomEvent(ey, {
			bubbles: !1,
			cancelable: !0,
			detail: {
				originalEvent: e,
				isContextMenu: !1
			}
		});
		r.dispatchEvent(a);
	};
	P(() => {
		$(e.isDisabled) || (n = window.setTimeout(() => {
			i().addEventListener("pointerdown", l, !0);
		}, 0), i().addEventListener("focusin", u, !0), L(() => {
			window.clearTimeout(n), i().removeEventListener("click", r), i().removeEventListener("pointerdown", l, !0), i().removeEventListener("focusin", u, !0);
		}));
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/IGYOA2ZZ.jsx
function ny(e) {
	let t = (t) => {
		t.key === qp.Escape && e.onEscapeKeyDown?.(t);
	};
	P(() => {
		if ($(e.isDisabled)) return;
		let n = e.ownerDocument?.() ?? Gp();
		n.addEventListener("keydown", t), L(() => {
			n.removeEventListener("keydown", t);
		});
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/3VFJM5NZ.jsx
var ry = de();
function iy() {
	return fe(ry);
}
function ay(e) {
	let t, n = iy(), [r, i] = B(e, [
		"ref",
		"disableOutsidePointerEvents",
		"excludedElements",
		"onEscapeKeyDown",
		"onPointerDownOutside",
		"onFocusOutside",
		"onInteractOutside",
		"onDismiss",
		"bypassTopMostLayerCheck"
	]), a = /* @__PURE__ */ new Set([]), o = (e) => {
		a.add(e);
		let t = n?.registerNestedLayer(e);
		return () => {
			a.delete(e), t?.();
		};
	};
	ty({
		shouldExcludeElement: (e) => t ? r.excludedElements?.some((t) => Hp(t(), e)) || [...a].some((t) => Hp(t, e)) : !1,
		onPointerDownOutside: (e) => {
			!t || Rv.isBelowPointerBlockingLayer(t) || !r.bypassTopMostLayerCheck && !Rv.isTopMostLayer(t) || (r.onPointerDownOutside?.(e), r.onInteractOutside?.(e), e.defaultPrevented || r.onDismiss?.());
		},
		onFocusOutside: (e) => {
			r.onFocusOutside?.(e), r.onInteractOutside?.(e), e.defaultPrevented || r.onDismiss?.();
		}
	}, () => t), ny({
		ownerDocument: () => Gp(t),
		onEscapeKeyDown: (e) => {
			!t || !Rv.isTopMostLayer(t) || (r.onEscapeKeyDown?.(e), !e.defaultPrevented && r.onDismiss && (e.preventDefault(), r.onDismiss()));
		}
	}), ae(() => {
		if (!t) return;
		Rv.addLayer({
			node: t,
			isPointerBlocking: r.disableOutsidePointerEvents,
			dismiss: r.onDismiss
		});
		let e = n?.registerNestedLayer(t);
		Rv.assignPointerEventToLayers(), Rv.disableBodyPointerEvents(t), L(() => {
			t && (Rv.removeLayer(t), e?.(), Rv.assignPointerEventToLayers(), Rv.restoreBodyPointerEvents(t));
		});
	}), P(ie([() => t, () => r.disableOutsidePointerEvents], ([e, t]) => {
		if (!e) return;
		let n = Rv.find(e);
		n && n.isPointerBlocking !== t && (n.isPointerBlocking = t, Rv.assignPointerEventToLayers()), t && Rv.disableBodyPointerEvents(e), L(() => {
			Rv.restoreBodyPointerEvents(e);
		});
	}, { defer: !0 }));
	let s = { registerNestedLayer: o };
	return R(ry.Provider, {
		value: s,
		get children() {
			return R(wh, z({
				as: "div",
				ref(e) {
					var n = Fp((e) => t = e, r.ref);
					typeof n == "function" && n(e);
				}
			}, i));
		}
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/E53DB7BS.jsx
function oy(e = {}) {
	let [t, n] = Ym({
		value: () => $(e.open),
		defaultValue: () => !!$(e.defaultOpen),
		onChange: (t) => e.onOpenChange?.(t)
	}), r = () => {
		n(!0);
	}, i = () => {
		n(!1);
	};
	return {
		isOpen: t,
		setIsOpen: n,
		open: r,
		close: i,
		toggle: () => {
			t() ? i() : r();
		}
	};
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/NGHEENNE.jsx
var sy = [
	"id",
	"aria-label",
	"aria-labelledby",
	"aria-describedby"
];
function cy(e) {
	let t = Wh(), n = Tm({ id: t.generateId("field") }, e);
	return P(() => L(t.registerField($(n.id)))), { fieldProps: {
		id: () => $(n.id),
		ariaLabel: () => $(n["aria-label"]),
		ariaLabelledBy: () => t.getAriaLabelledBy($(n.id), $(n["aria-label"]), $(n["aria-labelledby"])),
		ariaDescribedBy: () => t.getAriaDescribedBy($(n["aria-describedby"]))
	} };
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/QJIB6BDF.jsx
function ly(e, t) {
	P(ie(e, (e) => {
		if (e == null) return;
		let n = uy(e);
		n != null && (n.addEventListener("reset", t, { passive: !0 }), L(() => {
			n.removeEventListener("reset", t);
		}));
	}));
}
function uy(e) {
	return dy(e) ? e.form : e.closest("form");
}
function dy(e) {
	return e.matches("textarea, input, select, button");
}
//#endregion
//#region node_modules/.pnpm/@corvu+utils@0.4.2_solid-js@1.9.13/node_modules/@corvu/utils/dist/chunk/GZJAOTUE.jsx
var fy = (e, t) => {
	if (e.contains(t)) return !0;
	let n = t;
	for (; n;) {
		if (n === e) return !0;
		n = n._$host ?? n.parentElement;
	}
	return !1;
}, py = /* @__PURE__ */ new Map(), my = (e) => {
	P(() => {
		let t = Dh(e.style) ?? {}, n = Dh(e.properties) ?? [], r = {};
		for (let n in t) r[n] = e.element.style[n];
		let i = py.get(e.key);
		i ? i.activeCount++ : py.set(e.key, {
			activeCount: 1,
			originalStyles: r,
			properties: n.map((e) => e.key)
		}), Object.assign(e.element.style, e.style);
		for (let t of n) e.element.style.setProperty(t.key, t.value);
		L(() => {
			let t = py.get(e.key);
			if (t) {
				if (t.activeCount !== 1) {
					t.activeCount--;
					return;
				}
				py.delete(e.key);
				for (let [n, r] of Object.entries(t.originalStyles)) e.element.style[n] = r;
				for (let n of t.properties) e.element.style.removeProperty(n);
				e.element.style.length === 0 && e.element.removeAttribute("style"), e.cleanup?.();
			}
		});
	});
}, hy = (e, t) => {
	switch (t) {
		case "x": return [
			e.clientWidth,
			e.scrollLeft,
			e.scrollWidth
		];
		case "y": return [
			e.clientHeight,
			e.scrollTop,
			e.scrollHeight
		];
	}
}, gy = (e, t) => {
	let n = getComputedStyle(e), r = t === "x" ? n.overflowX : n.overflowY;
	return r === "auto" || r === "scroll" || e.tagName === "HTML" && r === "visible";
}, _y = (e, t, n) => {
	let r = t === "x" && window.getComputedStyle(e).direction === "rtl" ? -1 : 1, i = e, a = 0, o = 0, s = !1;
	do {
		let [e, c, l] = hy(i, t), u = l - e - r * c;
		(c !== 0 || u !== 0) && gy(i, t) && (a += u, o += c), i === (n ?? document.documentElement) ? s = !0 : i = i._$host ?? i.parentElement;
	} while (i && !s);
	return [a, o];
}, [vy, yy] = j([]), by = (e) => vy().indexOf(e) === vy().length - 1, xy = (e) => {
	let t = z({
		element: null,
		enabled: !0,
		hideScrollbar: !0,
		preventScrollbarShift: !0,
		preventScrollbarShiftMode: "padding",
		restoreScrollPosition: !0,
		allowPinchZoom: !1
	}, e), n = We(), r = [0, 0], i = null, a = null;
	P(() => {
		Dh(t.enabled) && (yy((e) => [...e, n]), L(() => {
			yy((e) => e.filter((e) => e !== n));
		}));
	}), P(() => {
		if (!Dh(t.enabled) || !Dh(t.hideScrollbar)) return;
		let { body: e } = document, n = window.innerWidth - e.offsetWidth;
		if (Dh(t.preventScrollbarShift)) {
			let r = { overflow: "hidden" }, i = [];
			n > 0 && (Dh(t.preventScrollbarShiftMode) === "padding" ? r.paddingRight = `calc(${window.getComputedStyle(e).paddingRight} + ${n}px)` : r.marginRight = `calc(${window.getComputedStyle(e).marginRight} + ${n}px)`, i.push({
				key: "--scrollbar-width",
				value: `${n}px`
			}));
			let a = window.scrollY, o = window.scrollX;
			my({
				key: "prevent-scroll",
				element: e,
				style: r,
				properties: i,
				cleanup: () => {
					Dh(t.restoreScrollPosition) && n > 0 && window.scrollTo(o, a);
				}
			});
		} else my({
			key: "prevent-scroll",
			element: e,
			style: { overflow: "hidden" }
		});
	}), P(() => {
		!by(n) || !Dh(t.enabled) || (document.addEventListener("wheel", s, { passive: !1 }), document.addEventListener("touchstart", o, { passive: !1 }), document.addEventListener("touchmove", c, { passive: !1 }), L(() => {
			document.removeEventListener("wheel", s), document.removeEventListener("touchstart", o), document.removeEventListener("touchmove", c);
		}));
	});
	let o = (e) => {
		r = Cy(e), i = null, a = null;
	}, s = (e) => {
		let n = e.target, r = Dh(t.element), i = Sy(e), a = Math.abs(i[0]) > Math.abs(i[1]) ? "x" : "y", o = wy(n, a, a === "x" ? i[0] : i[1], r), s;
		s = r && fy(r, n) ? !o : !0, s && e.cancelable && e.preventDefault();
	}, c = (e) => {
		let n = Dh(t.element), o = e.target, s;
		if (e.touches.length === 2) s = !Dh(t.allowPinchZoom);
		else {
			if (i == null || a === null) {
				let t = Cy(e).map((e, t) => r[t] - e), n = Math.abs(t[0]) > Math.abs(t[1]) ? "x" : "y";
				i = n, a = n === "x" ? t[0] : t[1];
			}
			if (o.type === "range") s = !1;
			else {
				let e = wy(o, i, a, n);
				s = n && fy(n, o) ? !e : !0;
			}
		}
		s && e.cancelable && e.preventDefault();
	};
}, Sy = (e) => [e.deltaX, e.deltaY], Cy = (e) => e.changedTouches[0] ? [e.changedTouches[0].clientX, e.changedTouches[0].clientY] : [0, 0], wy = (e, t, n, r) => {
	let [i, a] = _y(e, t, r !== null && fy(r, e) ? r : void 0);
	return !(n > 0 && Math.abs(i) <= 1 || n < 0 && Math.abs(a) < 1);
}, Ty = xy, Ey = de();
function Dy() {
	let e = fe(Ey);
	if (e === void 0) throw Error("[kobalte]: `useComboboxContext` must be used within a `Combobox` component");
	return e;
}
function Oy(e) {
	let t, n = Dy(), [r, i] = B(e, [
		"ref",
		"style",
		"onCloseAutoFocus",
		"onFocusOutside"
	]), a = () => {
		n.resetInputValue(n.listState().selectionManager().selectedKeys()), n.close(), setTimeout(() => {
			n.close();
		});
	}, o = (e) => {
		r.onFocusOutside?.(e), n.isOpen() && n.isModal() && e.preventDefault();
	};
	return Yv({
		isDisabled: () => !(n.isOpen() && n.isModal()),
		targets: () => {
			let e = [];
			t && e.push(t);
			let r = n.controlRef();
			return r && e.push(r), e;
		}
	}), Ty({
		element: () => t ?? null,
		enabled: () => n.contentPresent() && n.preventScroll()
	}), Uv({
		trapFocus: () => n.isOpen() && n.isModal(),
		onMountAutoFocus: (e) => {
			e.preventDefault();
		},
		onUnmountAutoFocus: (e) => {
			r.onCloseAutoFocus?.(e), e.defaultPrevented || (om(n.inputRef()), e.preventDefault());
		}
	}, () => t), R(H, {
		get when() {
			return n.contentPresent();
		},
		get children() {
			return R(xv.Positioner, { get children() {
				return R(ay, z({
					ref(e) {
						var i = Fp((e) => {
							n.setContentRef(e), t = e;
						}, r.ref);
						typeof i == "function" && i(e);
					},
					get disableOutsidePointerEvents() {
						return U(() => !!n.isModal())() && n.isOpen();
					},
					get excludedElements() {
						return [n.controlRef];
					},
					get style() {
						return Pp({
							"--kb-combobox-content-transform-origin": "var(--kb-popper-content-transform-origin)",
							position: "relative"
						}, r.style);
					},
					onFocusOutside: o,
					onDismiss: a
				}, () => n.dataset(), i));
			} });
		}
	});
}
function ky(e) {
	let t, n = Wh(), r = Dy(), [i, a, o] = B(Tm({ id: r.generateId("input") }, e), [
		"ref",
		"disabled",
		"onClick",
		"onInput",
		"onKeyDown",
		"onFocus",
		"onBlur",
		"onTouchEnd"
	], sy), s = () => r.listState().collection(), c = () => r.listState().selectionManager(), l = () => i.disabled || r.isDisabled() || n.isDisabled(), { fieldProps: u } = cy(a), d = (e) => {
		rm(e, i.onClick), r.triggerMode() === "focus" && !r.isOpen() && r.open(!1, "focus");
	}, f = (e) => {
		if (rm(e, i.onInput), n.isReadOnly() || l()) return;
		let t = e.target;
		r.setInputValue(t.value), t.value = r.inputValue() ?? "", r.isOpen() ? s().getSize() <= 0 && !r.allowsEmptyCollection() && r.close() : (s().getSize() > 0 || r.allowsEmptyCollection()) && r.open(!1, "input");
	}, p = (e) => {
		if (rm(e, i.onKeyDown), !(n.isReadOnly() || l())) switch (r.isOpen() && rm(e, r.onInputKeyDown), e.key) {
			case "Enter":
				if (r.isOpen()) {
					e.preventDefault();
					let t = c().focusedKey();
					t != null && c().select(t);
				}
				break;
			case "Tab":
				r.isOpen() && (r.close(), r.resetInputValue(r.listState().selectionManager().selectedKeys()));
				break;
			case "Escape":
				r.isOpen() ? (r.close(), r.resetInputValue(r.listState().selectionManager().selectedKeys())) : r.setInputValue("");
				break;
			case "ArrowDown":
				r.isOpen() || r.open(e.altKey ? !1 : "first", "manual");
				break;
			case "ArrowUp":
				r.isOpen() ? e.altKey && (r.close(), r.resetInputValue(r.listState().selectionManager().selectedKeys())) : r.open("last", "manual");
				break;
			case "ArrowLeft":
			case "ArrowRight":
				c().setFocusedKey(void 0);
				break;
			case "Backspace":
				if (r.removeOnBackspace() && c().selectionMode() === "multiple" && r.inputValue() === "") {
					let e = [...c().selectedKeys()].pop() ?? "";
					c().toggleSelection(e);
				}
				break;
		}
	}, m = (e) => {
		rm(e, i.onFocus), !r.isInputFocused() && r.setIsInputFocused(!0);
	}, h = (e) => {
		rm(e, i.onBlur), !(Hp(r.controlRef(), e.relatedTarget) || Hp(r.contentRef(), e.relatedTarget)) && r.setIsInputFocused(!1);
	}, g = 0;
	return R(wh, z({
		as: "input",
		ref(e) {
			var n = Fp((e) => {
				r.setInputRef(e), t = e;
			}, i.ref);
			typeof n == "function" && n(e);
		},
		get id() {
			return u.id();
		},
		get value() {
			return r.inputValue();
		},
		get required() {
			return n.isRequired();
		},
		get disabled() {
			return n.isDisabled();
		},
		get readonly() {
			return n.isReadOnly();
		},
		get placeholder() {
			return r.placeholder();
		},
		type: "text",
		role: "combobox",
		autoComplete: "off",
		autoCorrect: "off",
		spellCheck: "false",
		"aria-haspopup": "listbox",
		"aria-autocomplete": "list",
		get "aria-expanded"() {
			return r.isOpen();
		},
		get "aria-controls"() {
			return U(() => !!r.isOpen())() ? r.listboxId() : void 0;
		},
		get "aria-activedescendant"() {
			return r.activeDescendant();
		},
		get "aria-label"() {
			return u.ariaLabel();
		},
		get "aria-labelledby"() {
			return u.ariaLabelledBy();
		},
		get "aria-describedby"() {
			return u.ariaDescribedBy();
		},
		get "aria-invalid"() {
			return n.validationState() === "invalid" || void 0;
		},
		get "aria-required"() {
			return n.isRequired() || void 0;
		},
		get "aria-disabled"() {
			return n.isDisabled() || void 0;
		},
		get "aria-readonly"() {
			return n.isReadOnly() || void 0;
		},
		onClick: d,
		onInput: f,
		onKeyDown: p,
		onFocus: m,
		onBlur: h,
		onTouchEnd: (e) => {
			if (rm(e, i.onTouchEnd), !t || n.isReadOnly() || l()) return;
			if (e.timeStamp - g < 500) {
				e.preventDefault(), t.focus();
				return;
			}
			let a = e.target.getBoundingClientRect(), o = e.changedTouches[0], s = Math.ceil(a.left + .5 * a.width), c = Math.ceil(a.top + .5 * a.height);
			o.clientX === s && o.clientY === c && (e.preventDefault(), t.focus(), r.toggle(!1, "manual"), g = e.timeStamp);
		}
	}, () => r.dataset(), () => n.dataset(), o));
}
function Ay(e) {
	let t = Wh(), n = Dy(), [r, i] = B(Tm({ id: n.generateId("listbox") }, e), ["ref"]), a = () => t.getAriaLabelledBy(i.id, n.listboxAriaLabel(), void 0);
	return P(() => L(n.registerListboxId(i.id))), R(sg, z({
		ref(e) {
			var t = Fp(n.setListboxRef, r.ref);
			typeof t == "function" && t(e);
		},
		get state() {
			return n.listState();
		},
		get autoFocus() {
			return n.autoFocus();
		},
		shouldUseVirtualFocus: !0,
		shouldSelectOnPressUp: !0,
		shouldFocusOnHover: !0,
		get "aria-label"() {
			return n.listboxAriaLabel();
		},
		get "aria-labelledby"() {
			return a();
		},
		get renderItem() {
			return n.renderItem;
		},
		get renderSection() {
			return n.renderSection;
		},
		get virtualized() {
			return n.isVirtualized();
		}
	}, i));
}
function jy(e) {
	let t = Dy();
	return R(H, {
		get when() {
			return t.contentPresent();
		},
		get children() {
			return R(Tt, e);
		}
	});
}
function My(e) {
	let t = Wh(), n = Dy(), [r, i] = B(e, ["ref", "children"]), a = () => n.listState().selectionManager();
	return R(wh, z({
		as: "div",
		ref(e) {
			var t = Fp(n.setControlRef, r.ref);
			typeof t == "function" && t(e);
		}
	}, () => n.dataset(), () => t.dataset(), i, { get children() {
		return R(Ny, {
			state: {
				selectedOptions: () => n.selectedOptions(),
				remove: (e) => n.removeOptionFromSelection(e),
				clear: () => a().clearSelection()
			},
			get children() {
				return r.children;
			}
		});
	} }));
}
function Ny(e) {
	return U(pe(() => {
		let t = e.children;
		return Bp(t) ? t(e.state) : t;
	}));
}
function Py(e) {
	let t = Dy();
	return R(Jh, z({
		get collection() {
			return t.listState().collection();
		},
		get selectionManager() {
			return t.listState().selectionManager();
		},
		get isOpen() {
			return t.isOpen();
		},
		get isMultiple() {
			return t.isMultiple();
		},
		get isVirtualized() {
			return t.isVirtualized();
		},
		focusTrigger: () => t.inputRef()?.focus()
	}, e));
}
function Fy(e) {
	let t = Dy();
	return R(wh, z({
		as: "span",
		"aria-hidden": "true"
	}, () => t.dataset(), Tm({ children: "▼" }, e)));
}
var Iy = {
	focusAnnouncement: (e, t) => `${e}${t ? ", selected" : ""}`,
	countAnnouncement: (e) => {
		switch (e) {
			case 1: return "one option available";
			default: `${e}`;
		}
	},
	selectedAnnouncement: (e) => `${e}, selected`,
	triggerLabel: "Show suggestions",
	listboxLabel: "Suggestions"
};
function Ly(e) {
	let t = `combobox-${We()}`, n = qm({ sensitivity: "base" }), [r, i, a, o] = B(Tm({
		id: t,
		selectionMode: "single",
		allowsEmptyCollection: !1,
		disallowEmptySelection: !1,
		allowDuplicateSelectionEvents: !0,
		closeOnSelection: e.selectionMode === "single",
		removeOnBackspace: !0,
		gutter: 8,
		sameWidth: !0,
		modal: !1,
		defaultFilter: "contains",
		triggerMode: "input",
		translations: Iy
	}, e), /* @__PURE__ */ "noResetInputOnBlur.translations.itemComponent.sectionComponent.open.defaultOpen.onOpenChange.onInputChange.value.defaultValue.onChange.triggerMode.placeholder.options.optionValue.optionTextValue.optionLabel.optionDisabled.optionGroupChildren.keyboardDelegate.allowDuplicateSelectionEvents.disallowEmptySelection.defaultFilter.shouldFocusWrap.allowsEmptyCollection.closeOnSelection.removeOnBackspace.selectionBehavior.selectionMode.virtualized.modal.preventScroll.forceMount".split("."), [
		"getAnchorRect",
		"placement",
		"gutter",
		"shift",
		"flip",
		"slide",
		"overlap",
		"sameWidth",
		"fitViewport",
		"hideWhenDetached",
		"detachedPadding",
		"arrowPadding",
		"overflowPadding"
	], Vh), [s, c] = j(), [l, u] = j(), [d, f] = j(), [p, m] = j(), [h, g] = j(), [_, v] = j(), [y, b] = j(!1), [x, ee] = j(!1), [S, C] = j(!1), [w, T] = j(r.options), E = oy({
		open: () => r.open,
		defaultOpen: () => r.defaultOpen,
		onOpenChange: (e) => r.onOpenChange?.(e, I)
	}), [D, O] = Jm({
		defaultValue: () => "",
		onChange: (e) => {
			r.onInputChange?.(e), e === "" && r.selectionMode === "single" && !L.selectionManager().isEmpty() && r.value === void 0 && L.selectionManager().setSelectedKeys([]), L.selectionManager().setFocusedKey(void 0);
		}
	}), k = (e) => {
		let t = r.optionValue;
		return String(t == null ? e : Bp(t) ? t(e) : e[t]);
	}, te = (e) => {
		let t = r.optionLabel;
		return String(t == null ? e : Bp(t) ? t(e) : e[t]);
	}, A = (e) => {
		let t = r.optionTextValue;
		return String(t == null ? e : Bp(t) ? t(e) : e[t]);
	}, M = F(() => {
		let e = r.optionGroupChildren;
		return e == null ? r.options : r.options.flatMap((t) => t[e] ?? t);
	}), N = (e) => {
		let t = D() ?? "";
		if (Bp(r.defaultFilter)) return r.defaultFilter?.(e, t);
		let i = A(e);
		switch (r.defaultFilter) {
			case "startsWith": return n.startsWith(i, t);
			case "endsWith": return n.endsWith(i, t);
			case "contains": return n.contains(i, t);
		}
	}, ne = F(() => {
		let e = r.optionGroupChildren;
		if (e == null) return r.options.filter(N);
		let t = [];
		for (let n of r.options) {
			let r = n[e].filter(N);
			r.length !== 0 && t.push({
				...n,
				[e]: r
			});
		}
		return t;
	}), re = F(() => E.isOpen() ? S() ? r.options : ne() : w()), I = "focus", ae = (e) => [...e].map((e) => M().find((t) => k(t) === e)).filter((e) => e != null), L = dh({
		selectedKeys: () => r.value == null ? r.value : r.value.map(k),
		defaultSelectedKeys: () => r.defaultValue == null ? r.defaultValue : r.defaultValue.map(k),
		onSelectionChange: (e) => {
			r.onChange?.(ae(e)), r.closeOnSelection && E.isOpen() && e.size > 0 && (ue(), setTimeout(ue));
			let t = d();
			t && (t.setSelectionRange(t.value.length, t.value.length), om(t));
		},
		allowDuplicateSelectionEvents: () => $(r.allowDuplicateSelectionEvents),
		disallowEmptySelection: () => r.disallowEmptySelection,
		selectionBehavior: () => $(r.selectionBehavior),
		selectionMode: () => r.selectionMode,
		dataSource: re,
		getKey: () => r.optionValue,
		getTextValue: () => r.optionTextValue,
		getDisabled: () => r.optionDisabled,
		getSectionChildren: () => r.optionGroupChildren
	}), oe = F(() => ae(L.selectionManager().selectedKeys())), se = (e) => {
		L.selectionManager().toggleSelection(k(e));
	}, { present: ce } = Oh({
		show: () => r.forceMount || E.isOpen(),
		element: () => h() ?? null
	}), le = (e, t) => {
		if (r.triggerMode === "manual" && t !== "manual" || !(C(t === "manual") ? r.options.length > 0 : ne().length > 0) && !r.allowsEmptyCollection) return;
		I = t, b(e), E.open();
		let n = L.selectionManager().firstSelectedKey();
		n ?? (e === "first" ? n = L.collection().getFirstKey() : e === "last" && (n = L.collection().getLastKey())), L.selectionManager().setFocused(!0), L.selectionManager().setFocusedKey(n);
	}, ue = () => {
		E.close(), L.selectionManager().setFocused(!1), L.selectionManager().setFocusedKey(void 0);
	}, de = (e, t) => {
		E.isOpen() ? ue() : le(e, t);
	}, { formControlContext: fe } = Hh(a);
	ly(d, () => {
		let e = r.defaultValue ? [...r.defaultValue].map(k) : new Zm();
		L.selectionManager().setSelectedKeys(e);
	});
	let pe = F(() => $(r.keyboardDelegate) || new Zh(L.collection, _, void 0)), me = sh({
		selectionManager: () => L.selectionManager(),
		keyboardDelegate: pe,
		disallowTypeAhead: !0,
		disallowEmptySelection: !0,
		shouldFocusWrap: () => r.shouldFocusWrap,
		isVirtualized: !0
	}, d), he = (e) => {
		e && r.triggerMode === "focus" && le(!1, "focus"), ee(e), L.selectionManager().setFocused(e);
	}, ge = F(() => {
		let e = L.selectionManager().focusedKey();
		if (e) return _()?.querySelector(`[data-key="${e}"]`)?.id;
	}), _e = (e) => {
		if (r.selectionMode === "single") {
			let t = [...e][0], n = M().find((e) => k(e) === t);
			if (r.noResetInputOnBlur && !n) return;
			O(n ? te(n) : "");
		} else {
			if (r.noResetInputOnBlur) return;
			O("");
		}
	}, ve = (e) => r.itemComponent?.({ item: e }), ye = (e) => r.sectionComponent?.({ section: e });
	P(ie([ne, S], (e, t) => {
		if (E.isOpen() && t != null) {
			let e = t[0], n = t[1];
			T(n ? r.options : e);
		} else {
			let t = e[0], n = e[1];
			T(n ? r.options : t);
		}
	})), P(ie(D, () => {
		S() && C(!1);
	})), P(ie(() => L.selectionManager().selectedKeys(), _e));
	let be = "";
	P(() => {
		let e = L.selectionManager().focusedKey() ?? "", t = L.collection().getItem(e);
		if (em() && t != null && e !== be) {
			let n = L.selectionManager().isSelected(e);
			qv(r.translations?.focusAnnouncement(t?.textValue || "", n) ?? "");
		}
		e && (be = e);
	});
	let xe = Xh(L.collection()), Se = E.isOpen();
	P(() => {
		let e = Xh(L.collection()), t = E.isOpen(), n = t !== Se && (L.selectionManager().focusedKey() == null || em());
		t && (n || e !== xe) && qv(r.translations?.countAnnouncement(e) ?? ""), xe = e, Se = t;
	});
	let Ce = "";
	P(() => {
		let e = [...L.selectionManager().selectedKeys()].pop() ?? "", t = L.collection().getItem(e);
		em() && x() && t && e !== Ce && qv(r.translations?.selectedAnnouncement(t?.textValue || "") ?? ""), e && (Ce = e);
	});
	let we = F(() => ({
		"data-expanded": E.isOpen() ? "" : void 0,
		"data-closed": E.isOpen() ? void 0 : ""
	})), Te = {
		dataset: we,
		isOpen: E.isOpen,
		isDisabled: () => fe.isDisabled() ?? !1,
		isMultiple: () => $(r.selectionMode) === "multiple",
		isVirtualized: () => r.virtualized ?? !1,
		isModal: () => r.modal ?? !1,
		preventScroll: () => r.preventScroll ?? Te.isModal(),
		allowsEmptyCollection: () => r.allowsEmptyCollection ?? !1,
		shouldFocusWrap: () => r.shouldFocusWrap ?? !1,
		removeOnBackspace: () => r.removeOnBackspace ?? !0,
		selectedOptions: oe,
		isInputFocused: x,
		contentPresent: ce,
		autoFocus: y,
		inputValue: D,
		triggerMode: () => r.triggerMode,
		activeDescendant: ge,
		controlRef: l,
		inputRef: d,
		triggerRef: p,
		contentRef: h,
		listState: () => L,
		keyboardDelegate: pe,
		listboxId: s,
		triggerAriaLabel: () => r.translations?.triggerLabel,
		listboxAriaLabel: () => r.translations?.listboxLabel,
		setIsInputFocused: he,
		resetInputValue: _e,
		setInputValue: O,
		setControlRef: u,
		setInputRef: f,
		setTriggerRef: m,
		setContentRef: g,
		setListboxRef: v,
		open: le,
		close: ue,
		toggle: de,
		placeholder: () => r.placeholder,
		renderItem: ve,
		renderSection: ye,
		removeOptionFromSelection: se,
		onInputKeyDown: (e) => me.onKeyDown(e),
		generateId: Vp(() => $(a.id)),
		registerListboxId: Bh(c)
	};
	return R(Uh.Provider, {
		value: fe,
		get children() {
			return R(Ey.Provider, {
				value: Te,
				get children() {
					return R(xv, z({
						anchorRef: l,
						contentRef: h
					}, i, { get children() {
						return R(wh, z({
							as: "div",
							role: "group",
							get id() {
								return $(a.id);
							}
						}, () => fe.dataset(), we, o));
					} }));
				}
			});
		}
	});
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/OYES4GOP.jsx
function Ry(e, t) {
	let [n, r] = j(zy(t?.()));
	return P(() => {
		r(e()?.tagName.toLowerCase() || zy(t?.()));
	}), n;
}
function zy(e) {
	return zp(e) ? e : void 0;
}
Eh({}, {
	Button: () => Uy,
	Root: () => Hy
});
var By = [
	"button",
	"color",
	"file",
	"image",
	"reset",
	"submit"
];
function Vy(e) {
	let t = e.tagName.toLowerCase();
	return t === "button" ? !0 : t === "input" && e.type ? By.indexOf(e.type) !== -1 : !1;
}
function Hy(e) {
	let t, [n, r] = B(Tm({ type: "button" }, e), [
		"ref",
		"type",
		"disabled"
	]), i = Ry(() => t, () => "button"), a = F(() => {
		let e = i();
		return e == null ? !1 : Vy({
			tagName: e,
			type: n.type
		});
	}), o = F(() => i() === "input"), s = F(() => i() === "a" && t?.getAttribute("href") != null);
	return R(wh, z({
		as: "button",
		ref(e) {
			var r = Fp((e) => t = e, n.ref);
			typeof r == "function" && r(e);
		},
		get type() {
			return U(() => !!(a() || o()))() ? n.type : void 0;
		},
		get role() {
			return !a() && !s() ? "button" : void 0;
		},
		get tabIndex() {
			return !a() && !s() && !n.disabled ? 0 : void 0;
		},
		get disabled() {
			return U(() => !!(a() || o()))() ? n.disabled : void 0;
		},
		get "aria-disabled"() {
			return !a() && !o() && n.disabled ? !0 : void 0;
		},
		get "data-disabled"() {
			return n.disabled ? "" : void 0;
		}
	}, r));
}
var Uy = Hy;
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/FOXVCQFV.jsx
function Wy(e) {
	let t, n = Wh(), [r, i] = B(Tm({ id: n.generateId("label") }, e), ["ref"]), a = Ry(() => t, () => "label");
	return P(() => L(n.registerLabel(i.id))), R(wh, z({
		as: "label",
		ref(e) {
			var n = Fp((e) => t = e, r.ref);
			typeof n == "function" && n(e);
		},
		get for() {
			return U(() => a() === "label")() ? n.fieldId() : void 0;
		}
	}, () => n.dataset(), i));
}
//#endregion
//#region node_modules/.pnpm/@kobalte+core@0.13.11_solid-js@1.9.13/node_modules/@kobalte/core/dist/chunk/ZZYKR3VO.jsx
function Gy(e) {
	let t = Wh(), [n, r] = B(Tm({ id: t.generateId("error-message") }, e), ["forceMount"]), i = () => t.validationState() === "invalid";
	return P(() => {
		i() && L(t.registerErrorMessage(r.id));
	}), R(H, {
		get when() {
			return n.forceMount || i();
		},
		get children() {
			return R(wh, z({ as: "div" }, () => t.dataset(), r));
		}
	});
}
Eh({}, {
	Arrow: () => fv,
	Combobox: () => Jy,
	Content: () => Oy,
	Control: () => My,
	Description: () => Gh,
	ErrorMessage: () => Gy,
	HiddenSelect: () => Py,
	Icon: () => Fy,
	Input: () => ky,
	Item: () => rg,
	ItemDescription: () => ig,
	ItemIndicator: () => ag,
	ItemLabel: () => og,
	Label: () => Wy,
	Listbox: () => Ay,
	Portal: () => jy,
	Root: () => Ky,
	Section: () => cg,
	Trigger: () => qy,
	useComboboxContext: () => Dy
});
function Ky(e) {
	let [t, n] = B(e, [
		"value",
		"defaultValue",
		"onChange",
		"multiple"
	]), r = F(() => t.value == null || t.multiple ? t.value : [t.value]), i = F(() => t.defaultValue == null || t.multiple ? t.defaultValue : [t.defaultValue]);
	return R(Ly, z({
		get value() {
			return r();
		},
		get defaultValue() {
			return i();
		},
		onChange: (e) => {
			t.multiple ? t.onChange?.(e ?? []) : t.onChange?.(e[0] ?? null);
		},
		get selectionMode() {
			return t.multiple ? "multiple" : "single";
		}
	}, n));
}
function qy(e) {
	let t = Wh(), n = Dy(), [r, i] = B(Tm({ id: n.generateId("trigger") }, e), [
		"ref",
		"disabled",
		"onPointerDown",
		"onClick",
		"aria-labelledby"
	]), a = () => r.disabled || n.isDisabled() || t.isDisabled() || t.isReadOnly(), o = (e) => {
		rm(e, r.onPointerDown), e.currentTarget.dataset.pointerType = e.pointerType, !a() && e.pointerType !== "touch" && e.button === 0 && (e.preventDefault(), n.toggle(!1, "manual"));
	}, s = (e) => {
		rm(e, r.onClick), a() || (e.currentTarget.dataset.pointerType === "touch" && n.toggle(!1, "manual"), n.inputRef()?.focus());
	}, c = () => t.getAriaLabelledBy(i.id, n.triggerAriaLabel(), r["aria-labelledby"]);
	return R(Hy, z({
		ref(e) {
			var t = Fp(n.setTriggerRef, r.ref);
			typeof t == "function" && t(e);
		},
		get disabled() {
			return a();
		},
		tabIndex: -1,
		"aria-haspopup": "listbox",
		get "aria-expanded"() {
			return n.isOpen();
		},
		get "aria-controls"() {
			return U(() => !!n.isOpen())() ? n.listboxId() : void 0;
		},
		get "aria-label"() {
			return n.triggerAriaLabel();
		},
		get "aria-labelledby"() {
			return c();
		},
		onPointerDown: o,
		onClick: s
	}, () => n.dataset(), i));
}
var Jy = Object.assign(Ky, {
	Arrow: fv,
	Content: Oy,
	Control: My,
	Description: Gh,
	ErrorMessage: Gy,
	HiddenSelect: Py,
	Icon: Fy,
	Input: ky,
	Item: rg,
	ItemDescription: ig,
	ItemIndicator: ag,
	ItemLabel: og,
	Label: Wy,
	Listbox: Ay,
	Portal: jy,
	Section: cg,
	Trigger: qy
});
//#endregion
//#region src/components/ui/ComboboxInput.tsx
function Yy(e) {
	return R(Jy.Item, {
		get item() {
			return e.item;
		},
		get children() {
			return R(Jy.ItemLabel, { get children() {
				return e.item.rawValue;
			} });
		}
	});
}
function Xy(e) {
	function t(t) {
		t.key === "Enter" && e.onEnter && (t.preventDefault(), e.onEnter());
	}
	return R(Jy, {
		get value() {
			return e.value;
		},
		onChange: (t) => e.onChange(t ?? ""),
		get options() {
			return e.options;
		},
		optionValue: (e) => e,
		optionLabel: (e) => e,
		optionTextValue: (e) => e,
		get placeholder() {
			return e.placeholder ?? "Type to search…";
		},
		class: "combobox-wrapper",
		itemComponent: Yy,
		get children() {
			return [R(Jy.Control, {
				class: "combobox-control",
				get children() {
					return R(Jy.Input, {
						class: "search-input",
						onKeyDown: (e) => t(e)
					});
				}
			}), R(Jy.Portal, { get children() {
				return R(Jy.Content, {
					class: "combobox-content",
					get children() {
						return R(Jy.Listbox, { class: "combobox-listbox" });
					}
				});
			} })];
		}
	});
}
//#endregion
//#region src/features/diagrams/components/SvgToolbar.tsx
var Zy = /*#__PURE__*/ W("<div class=diagram-toolbar>"), Qy = /*#__PURE__*/ W("<button class=icon-btn title=\"Copy SVG\">"), $y = /*#__PURE__*/ W("<svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M3 8.5l3 3 7-7\"stroke=currentColor stroke-width=1.5 stroke-linecap=round stroke-linejoin=round>"), eb = /*#__PURE__*/ W("<svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><rect x=5 y=5 width=8 height=8 rx=1.5 stroke=currentColor stroke-width=1.2></rect><path d=\"M3 11V3.5A.5.5 0 013.5 3H11\"stroke=currentColor stroke-width=1.2 stroke-linecap=round>"), tb = /*#__PURE__*/ W("<button class=icon-btn title=\"Download SVG\"><svg width=16 height=16 viewBox=\"0 0 16 16\"fill=none><path d=\"M8 2v8m0 0l-3-3m3 3l3-3M3 12.5h10\"stroke=currentColor stroke-width=1.2 stroke-linecap=round stroke-linejoin=round>");
function nb(e) {
	let [t, n] = j(!1);
	function r() {
		e.onCopy?.(), n(!0), setTimeout(() => n(!1), 1500);
	}
	return (() => {
		var n = Zy();
		return X(n, (() => {
			var n = U(() => !!e.onCopy);
			return () => n() && (() => {
				var e = Qy();
				return e.$$click = r, X(e, (() => {
					var e = U(() => !!t());
					return () => e() ? $y() : eb();
				})()), e;
			})();
		})(), null), X(n, (() => {
			var t = U(() => !!e.onDownload);
			return () => t() && (() => {
				var t = tb();
				return J(t, "click", e.onDownload, !0), t;
			})();
		})(), null), n;
	})();
}
G(["click"]);
//#endregion
//#region src/features/diagrams/Diagrams.tsx
var rb = /*#__PURE__*/ W("<input class=search-input type=number min=1 max=5 style=max-width:80px>"), ib = /*#__PURE__*/ W("<div class=card style=\"padding:12px 20px\"><div style=display:flex;gap:8px;align-items:center><button class=\"filter-pill active\">Generate"), ab = /*#__PURE__*/ W("<div class=diagram-container><div class=loading-overlay><div class=spinner></div> Generating diagram..."), ob = /*#__PURE__*/ W("<div class=diagram-container>"), sb = /*#__PURE__*/ W("<div class=diagram-container><div class=loading-overlay style=color:var(--red)>Error: "), cb = /*#__PURE__*/ W("<div class=diagram-container><div class=loading-overlay>Select options and click Generate"), lb = /*#__PURE__*/ W("<div class=card>");
function ub(e) {
	let t = e.store, n = t.getState(), r = () => n().diagrams, [i, a] = j(n().diagrams.active), [o, s] = j(""), [c, l] = j("2"), [u, d] = j(""), [f, p] = j(null), m = null;
	L(() => {
		m && clearTimeout(m);
	}), ae(() => {
		t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: { view: "diagrams" }
			}
		}), r().itemsLoaded || t.dispatch({
			tag: "diagrams",
			action: { tag: "loadItems" }
		});
	});
	function h() {
		let e = i();
		e === "calls" ? t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: {
					focal: o(),
					depth: c()
				}
			}
		}) : e === "dw-tables" ? t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: { table: u() }
			}
		}) : e === "sql-lineage" ? t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: { focal: o() }
			}
		}) : e === "table-lineage" ? t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: { table: u() }
			}
		}) : e === "proc-tables" && t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: {
					table: u(),
					focal: o()
				}
			}
		}), t.dispatch({
			tag: "diagrams",
			action: { tag: "generate" }
		});
	}
	function g(e) {
		let t = e.target.closest("a");
		if (!t) return;
		let n = ls(us(t));
		n && (e.preventDefault(), e.stopPropagation(), x(n.kind, n.name, "detail"));
	}
	function _(e) {
		m &&= (clearTimeout(m), null);
		let t = e.target.closest("a");
		if (!t) return;
		let n = ls(us(t));
		if (!n) {
			p(null);
			return;
		}
		let r = t.getBoundingClientRect();
		p({
			x: r.left + r.width / 2,
			y: r.top - 8,
			kind: n.kind,
			name: n.name,
			meta: n.meta
		});
	}
	function v(e) {
		let t = e.relatedTarget;
		t && (t.closest("a") || t.closest(".diagram-tooltip")) || (m = setTimeout(() => p(null), 150));
	}
	function y() {
		m &&= (clearTimeout(m), null);
	}
	function b(e) {
		let t = e.relatedTarget;
		t && t.closest("a") || (m = setTimeout(() => p(null), 150));
	}
	function x(e, n, r) {
		p(null), r === "detail" ? e === "object" ? t.dispatch({
			tag: "objects",
			action: {
				tag: "select",
				name: n
			}
		}) : t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "tableDetail",
					name: n
				}
			}
		}) : r === "focus" && (e === "object" ? (s(n), t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: { focal: n }
			}
		})) : (d(n), t.dispatch({
			tag: "diagrams",
			action: {
				tag: "params",
				params: { table: n }
			}
		})), t.dispatch({
			tag: "diagrams",
			action: { tag: "generate" }
		}));
	}
	function ee() {
		let e = r().svg;
		if (!e) return;
		let t = new Blob([e], { type: "image/svg+xml" }), n = URL.createObjectURL(t), a = document.createElement("a");
		a.href = n, a.download = `${i()}.svg`, a.click(), URL.revokeObjectURL(n);
	}
	function S() {
		let e = r().svg;
		e && navigator.clipboard.writeText(e);
	}
	let C = () => !cs.has(i());
	return [
		R(zh, {
			get value() {
				return i();
			},
			onChange: (e) => {
				a(e), t.dispatch({
					tag: "diagrams",
					action: {
						tag: "select",
						kind: e
					}
				}), cs.has(e) && t.dispatch({
					tag: "diagrams",
					action: { tag: "generate" }
				});
			},
			get children() {
				return R(zh.List, {
					class: "tab-bar",
					get children() {
						return R(V, {
							each: [
								"inheritance",
								"calls",
								"dw-tables",
								"heatmap",
								"sql-lineage",
								"table-lineage",
								"proc-tables"
							],
							children: (e) => R(zh.Trigger, {
								value: e,
								class: "tab-btn",
								children: e
							})
						});
					}
				});
			}
		}),
		R(H, {
			get when() {
				return C();
			},
			get children() {
				var e = ib(), t = e.firstChild, n = t.firstChild;
				return X(t, R(H, {
					get when() {
						return i() === "calls";
					},
					get children() {
						return [R(Xy, {
							get value() {
								return o();
							},
							onChange: s,
							get options() {
								return r().objectNames;
							},
							placeholder: "Focal object",
							onEnter: h
						}), (() => {
							var e = rb();
							return e.$$keydown = (e) => {
								e.key === "Enter" && h();
							}, e.$$input = (e) => l(e.currentTarget.value), N(() => e.value = c()), e;
						})()];
					}
				}), n), X(t, R(H, {
					get when() {
						return i() === "dw-tables";
					},
					get children() {
						return R(Xy, {
							get value() {
								return u();
							},
							onChange: d,
							get options() {
								return r().tableNames;
							},
							placeholder: "Filter table (optional)",
							onEnter: h
						});
					}
				}), n), X(t, R(H, {
					get when() {
						return i() === "table-lineage";
					},
					get children() {
						return R(Xy, {
							get value() {
								return u();
							},
							onChange: d,
							get options() {
								return r().tableNames;
							},
							placeholder: "Table name (required)",
							onEnter: h
						});
					}
				}), n), X(t, R(H, {
					get when() {
						return i() === "proc-tables";
					},
					get children() {
						return [R(Xy, {
							get value() {
								return u();
							},
							onChange: d,
							get options() {
								return r().tableNames;
							},
							placeholder: "Table name (optional)",
							onEnter: h
						}), R(Xy, {
							get value() {
								return o();
							},
							onChange: s,
							get options() {
								return r().objectNames;
							},
							placeholder: "Focal object (optional)",
							onEnter: h
						})];
					}
				}), n), n.$$click = h, e;
			}
		}),
		(() => {
			var e = lb();
			return X(e, R(H, {
				get when() {
					return r().loading;
				},
				get children() {
					return ab();
				}
			}), null), X(e, R(H, {
				get when() {
					return r().svg;
				},
				get children() {
					return [R(nb, {
						onCopy: S,
						onDownload: ee
					}), (() => {
						var e = ob();
						return e.$$mouseout = v, e.$$mouseover = _, e.$$click = g, N(() => e.innerHTML = r().svg), e;
					})()];
				}
			}), null), X(e, R(H, {
				get when() {
					return r().error;
				},
				get children() {
					var e = sb(), t = e.firstChild;
					return t.firstChild, X(t, () => r().error, null), e;
				}
			}), null), X(e, R(H, {
				get when() {
					return U(() => !r().loading && !r().svg)() && !r().error;
				},
				get children() {
					return cb();
				}
			}), null), e;
		})(),
		R(H, {
			get when() {
				return f();
			},
			get children() {
				return R(Ms, {
					get x() {
						return f().x;
					},
					get y() {
						return f().y;
					},
					get name() {
						return f().name;
					},
					get kind() {
						return f().meta.kind;
					},
					get meta() {
						return f().meta;
					},
					get actions() {
						return [{
							label: "detail",
							onClick: () => x(f().kind, f().name, "detail")
						}, ...ss.has(i()) ? [{
							label: "focus",
							onClick: () => x(f().kind, f().name, "focus")
						}] : []];
					},
					onMouseOver: y,
					onMouseOut: b
				});
			}
		})
	];
}
G([
	"input",
	"keydown",
	"click",
	"mouseover",
	"mouseout"
]);
//#endregion
//#region src/features/queries/Queries.tsx
var db = /*#__PURE__*/ W("<td>"), fb = /*#__PURE__*/ W("<div style=margin-top:6px><button class=filter-pill style=font-size:11px>"), pb = /*#__PURE__*/ W("<div style=\"margin-top:8px;border:1px solid var(--border);border-radius:4px;overflow:hidden\"><div style=\"display:flex;justify-content:space-between;align-items:center;padding:4px 8px;background:var(--bg-secondary);font-size:11px;color:var(--text-muted)\"><span></span><button class=\"filter-pill active\"style=\"font-size:11px;padding:2px 8px\">Run</button></div><textarea style=width:100%;min-height:80px;padding:8px;font-family:monospace;font-size:12px;background:var(--bg-code);color:var(--text);border:none;resize:vertical;box-sizing:border-box>"), mb = /*#__PURE__*/ W("<div style=display:flex;gap:6px;margin-top:8px;flex-wrap:wrap;align-items:center><span style=font-size:11px;color:var(--text-muted);white-space:nowrap>Recent:"), hb = /*#__PURE__*/ W("<div style=\"padding:8px 16px 0;font-size:11px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em\">SQL Queries"), gb = /*#__PURE__*/ W("<p style=\"color:var(--red);padding:8px 16px\">"), _b = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Ask</h2></div><div style=\"padding:12px 16px;border-bottom:1px solid var(--border)\"><div style=display:flex;gap:8px;align-items:flex-start><textarea class=search-input placeholder=\"Ask pb anything… or start with SELECT to write SQL directly.\"rows=2 style=\"flex:1;resize:vertical;min-height:40px;padding:8px 10px;font-size:13px;font-family:inherit\"></textarea><button class=\"filter-pill active\"style=white-space:nowrap;align-self:flex-end>"), vb = /*#__PURE__*/ W("<button class=filter-pill style=font-size:11px;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap>"), yb = /*#__PURE__*/ W("<button class=filter-pill>"), bb = /*#__PURE__*/ W("<div style=color:var(--red);font-size:12px;margin-top:4px>Required: "), xb = /*#__PURE__*/ W("<div style=\"margin:8px 16px;padding-bottom:12px;border-bottom:1px solid var(--border)\"><div style=font-weight:600;margin-bottom:4px></div><div style=font-size:12px;color:var(--text-muted);margin-bottom:8px></div><div style=display:flex;gap:6px;align-items:center;flex-wrap:wrap><button class=\"filter-pill active\">Run"), Sb = /*#__PURE__*/ W("<input class=search-input style=\"max-width:160px;padding:6px 10px;font-size:12px\">"), Cb = /*#__PURE__*/ W("<div style=display:flex;gap:8px;padding:8px;align-items:center;font-size:12px><button class=filter-pill> Prev</button><span>Page <!> of </span><button class=filter-pill>Next "), wb = /*#__PURE__*/ W("<div class=card style=\"margin:12px 16px 0\"><div class=card-header><h3> — <!> rows</h3></div><table class=data-table><thead><tr></tr></thead><tbody>"), Tb = /*#__PURE__*/ W("<th style=cursor:pointer;user-select:none> "), Eb = /*#__PURE__*/ W("<tr>"), Db = 50, Ob = {
	object: "object",
	procedure: "procedure",
	datawindow: "datawindow",
	table: "table"
};
function kb(e) {
	let t = e.store, n = t.getState(), r = () => n().queries, [i, a] = j({}), [o, s] = j(/* @__PURE__ */ new Set()), [c, l] = j(/* @__PURE__ */ new Set());
	ae(() => {
		r().items.length || t.dispatch({
			tag: "queries",
			action: { tag: "load" }
		});
	});
	function u(e, t, n) {
		a((r) => ({
			...r,
			[`${e}.${t}`]: n
		})), c().has(e) && l((t) => {
			let n = new Set(t);
			return n.delete(e), n;
		});
	}
	function d(e) {
		let t = i();
		return e.params.filter((n) => n.default === null && !(t[`${e.name}.${n.name}`] ?? "").trim()).map((e) => e.name);
	}
	function f(e) {
		if (d(e).length > 0) {
			l((t) => new Set(t).add(e.name));
			return;
		}
		let n = {}, r = i();
		for (let t of e.params) {
			let i = r[`${e.name}.${t.name}`];
			i ? n[t.name] = i : t.default && (n[t.name] = t.default);
		}
		t.dispatch({
			tag: "queries",
			action: {
				tag: "run",
				name: e.name,
				params: n
			}
		});
	}
	function p(e) {
		s((t) => {
			let n = new Set(t);
			return n.has(e) ? n.delete(e) : n.add(e), n;
		});
	}
	function m(e) {
		e.key === "Enter" && !e.shiftKey && (e.preventDefault(), t.dispatch({
			tag: "queries",
			action: { tag: "submit-ask" }
		}));
	}
	let h = () => r().isSqlMode ? "SQL query" : "generated query";
	function g() {
		let e = r(), t = e.results;
		if (!t || "error" in t || !("rows" in t)) return [];
		let n = t.rows;
		if (!e.sortCol) return n;
		let i = e.sortCol, a = e.sortDir;
		return [...n].sort((e, t) => {
			let n = String(e[i] ?? "").localeCompare(String(t[i] ?? ""), void 0, { numeric: !0 });
			return a === "asc" ? n : -n;
		});
	}
	function _() {
		let e = r().page;
		return g().slice(e * Db, (e + 1) * Db);
	}
	function v() {
		return Math.max(1, Math.ceil(g().length / Db));
	}
	function y(e, n) {
		let i = String(n[e.name] ?? ""), a = r().results, o = (a && "columns" in a ? a.columns : []).find((e) => e.entity_type === "object"), s = o ? String(n[o.name] ?? "") : null;
		t.dispatch({
			tag: "queries",
			action: {
				tag: "navigate-to-entity",
				entityType: e.entity_type,
				entityName: i,
				objectName: s
			}
		});
	}
	function b(e, t) {
		let n = t[e.name], r = n == null ? "" : String(n), i = r && e.entity_type ? Ob[e.entity_type] : null;
		return i ? (() => {
			var n = db();
			return X(n, R(mc, {
				type: i,
				name: r,
				onClick: () => y(e, t)
			})), n;
		})() : (() => {
			var e = db();
			return X(e, r), e;
		})();
	}
	let x = () => {
		let e = r().results;
		return !!(e && "rows" in e && e.rows?.length);
	};
	return (() => {
		var e = _b(), n = e.firstChild.nextSibling, a = n.firstChild.firstChild, s = a.nextSibling;
		return a.$$keydown = m, a.$$input = (e) => t.dispatch({
			tag: "queries",
			action: {
				tag: "set-ask-text",
				text: e.currentTarget.value
			}
		}), s.$$click = () => t.dispatch({
			tag: "queries",
			action: { tag: "submit-ask" }
		}), X(s, () => r().loading ? "Running…" : "Ask"), X(n, R(H, {
			get when() {
				return r().generatedSql !== null;
			},
			get children() {
				var e = fb(), n = e.firstChild;
				return n.$$click = () => t.dispatch({
					tag: "queries",
					action: { tag: "toggle-query-pane" }
				}), X(n, (() => {
					var e = U(() => !!r().queryPaneOpen);
					return () => e() ? [
						R(Ei, { size: 12 }),
						" Hide ",
						U(h)
					] : [
						R(bi, { size: 12 }),
						" Show ",
						U(h)
					];
				})()), e;
			}
		}), null), X(n, R(H, {
			get when() {
				return U(() => !!r().queryPaneOpen)() && r().generatedSql !== null;
			},
			get children() {
				var e = pb(), n = e.firstChild, i = n.firstChild, a = i.nextSibling, o = n.nextSibling;
				return X(i, () => r().isSqlMode ? "SQL Query" : "Generated Query"), a.$$click = () => {
					let e = r().generatedSql;
					e && t.dispatch({
						tag: "queries",
						action: {
							tag: "run-sql",
							sql: e
						}
					});
				}, o.$$input = (e) => t.dispatch({
					tag: "queries",
					action: {
						tag: "set-generated-sql",
						sql: e.currentTarget.value
					}
				}), N(() => o.value = r().generatedSql ?? ""), e;
			}
		}), null), X(n, R(H, {
			get when() {
				return U(() => r().recentQueries.length > 0)() && !r().askText.trim();
			},
			get children() {
				var e = mb();
				return e.firstChild, X(e, R(V, {
					get each() {
						return r().recentQueries;
					},
					children: (e) => (() => {
						var n = vb();
						return n.$$click = () => t.dispatch({
							tag: "queries",
							action: {
								tag: "run-recent",
								text: e
							}
						}), K(n, "title", e), X(n, (() => {
							var t = U(() => e.length > 40);
							return () => t() ? e.slice(0, 40) + "…" : e;
						})()), n;
					})()
				}), null), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return r().items.length > 0;
			},
			get children() {
				return [hb(), R(V, {
					get each() {
						return r().items;
					},
					children: (e) => {
						let t = () => d(e), n = () => t().length > 0;
						return (() => {
							var r = xb(), a = r.firstChild, s = a.nextSibling, l = s.nextSibling, d = l.firstChild;
							return X(a, () => e.name), X(s, () => e.description), X(l, R(V, {
								get each() {
									return e.params;
								},
								children: (t) => (() => {
									var n = Sb();
									return n.$$keydown = (t) => {
										t.key === "Enter" && f(e);
									}, n.$$input = (n) => u(e.name, t.name, n.currentTarget.value), N((r) => {
										var a = t.name + (t.default ? ` (${t.default})` : ""), o = { ...t.default === null && c().has(e.name) && !(i()[`${e.name}.${t.name}`] ?? "").trim() ? {
											border: "1px solid var(--red)",
											"box-shadow": "0 0 0 1px var(--red)"
										} : {} };
										return a !== r.e && K(n, "placeholder", r.e = a), r.t = ct(n, o, r.t), r;
									}, {
										e: void 0,
										t: void 0
									}), n;
								})()
							}), d), d.$$click = () => f(e), X(l, R(H, {
								get when() {
									return e.sql;
								},
								get children() {
									var t = yb();
									return t.$$click = () => p(e.name), X(t, () => o().has(e.name) ? "Hide SQL" : "SQL"), t;
								}
							}), null), X(r, R(H, {
								get when() {
									return U(() => !!c().has(e.name))() && t().length > 0;
								},
								get children() {
									var e = bb();
									return e.firstChild, X(e, () => t().join(", "), null), e;
								}
							}), null), X(r, R(H, {
								get when() {
									return U(() => !!o().has(e.name))() && e.sql;
								},
								get children() {
									return R(Sd, {
										get code() {
											return e.sql;
										},
										style: {
											"margin-top": "8px",
											"font-size": "11px"
										}
									});
								}
							}), null), N((t) => {
								var r = n(), i = e.name;
								return r !== t.e && (d.disabled = t.e = r), i !== t.t && K(d, "data-query", t.t = i), t;
							}, {
								e: void 0,
								t: void 0
							}), r;
						})();
					}
				})];
			}
		}), null), X(e, R(H, {
			get when() {
				return r().results;
			},
			get children() {
				return R(H, {
					get when() {
						return "error" in (r().results ?? {});
					},
					get fallback() {
						return R(H, {
							get when() {
								return x();
							},
							get children() {
								var e = wb(), n = e.firstChild, i = n.firstChild, a = i.firstChild, o = a.nextSibling;
								o.nextSibling;
								var s = n.nextSibling.firstChild, c = s.firstChild, l = s.nextSibling;
								return X(i, () => r().resultsName, a), X(i, () => r().results.rows.length, o), X(c, R(V, {
									get each() {
										return r().results.columns;
									},
									children: (e) => (() => {
										var n = Tb(), i = n.firstChild;
										return n.$$click = () => t.dispatch({
											tag: "queries",
											action: {
												tag: "sort",
												col: e.name
											}
										}), X(n, () => e.name, i), X(n, R(H, {
											get when() {
												return r().sortCol === e.name;
											},
											get fallback() {
												return R(mi, {
													size: 11,
													style: {
														opacity: "0.3",
														"vertical-align": "middle"
													}
												});
											},
											get children() {
												return U(() => r().sortDir === "asc")() ? R(Ei, {
													size: 11,
													style: { "vertical-align": "middle" }
												}) : R(bi, {
													size: 11,
													style: { "vertical-align": "middle" }
												});
											}
										}), null), n;
									})()
								})), X(l, R(V, {
									get each() {
										return _();
									},
									children: (e) => (() => {
										var t = Eb();
										return X(t, R(V, {
											get each() {
												return r().results.columns;
											},
											children: (t) => b(t, e)
										})), t;
									})()
								})), X(e, R(H, {
									get when() {
										return v() > 1;
									},
									get children() {
										var e = Cb(), n = e.firstChild, i = n.firstChild, a = n.nextSibling, o = a.firstChild.nextSibling;
										o.nextSibling;
										var s = a.nextSibling;
										return s.firstChild, n.$$click = () => t.dispatch({
											tag: "queries",
											action: {
												tag: "set-page",
												page: r().page - 1
											}
										}), X(n, R(Si, { size: 13 }), i), X(a, () => r().page + 1, o), X(a, v, null), s.$$click = () => t.dispatch({
											tag: "queries",
											action: {
												tag: "set-page",
												page: r().page + 1
											}
										}), X(s, R(wi, { size: 13 }), null), N((e) => {
											var t = r().page === 0, i = r().page >= v() - 1;
											return t !== e.e && (n.disabled = e.e = t), i !== e.t && (s.disabled = e.t = i), e;
										}, {
											e: void 0,
											t: void 0
										}), e;
									}
								}), null), e;
							}
						});
					},
					get children() {
						var e = gb();
						return X(e, () => r().results.error), e;
					}
				});
			}
		}), null), N((e) => {
			var t = r().loading, n = r().loading || !r().askText.trim();
			return t !== e.e && (a.disabled = e.e = t), n !== e.t && (s.disabled = e.t = n), e;
		}, {
			e: void 0,
			t: void 0
		}), N(() => a.value = r().askText), e;
	})();
}
G([
	"input",
	"keydown",
	"click"
]);
//#endregion
//#region src/features/search/Search.tsx
var Ab = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Objects (<!>)</h3></div><table class=data-table><thead><tr><th>Name</th><th>Kind</th><th>File</th></tr></thead><tbody>"), jb = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>Procedures (<!>)</h3></div><table class=data-table><thead><tr><th>Object</th><th>Name</th><th>Type</th><th>Line</th></tr></thead><tbody>"), Mb = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>DataWindow Controls (<!>)</h3></div><table class=data-table><thead><tr><th>DW</th><th>Control</th><th>Type</th></tr></thead><tbody>"), Nb = /*#__PURE__*/ W("<div class=card><div class=card-header><h3>DB Tables (<!>)</h3></div><table class=data-table><thead><tr><th>Table</th><th>DW refs</th><th>PS refs</th></tr></thead><tbody>"), Pb = /*#__PURE__*/ W("<div class=card><p style=color:var(--text-muted)>No results found"), Fb = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell></td><td><span></span></td><td style=font-size:11px;color:var(--text-muted)>"), Ib = /*#__PURE__*/ W("<tr class=clickable><td></td><td class=name-cell></td><td><span></span></td><td style=font-size:11px;color:var(--text-muted)>"), Lb = /*#__PURE__*/ W("<tr class=clickable><td class=name-cell></td><td></td><td>"), Rb = /*#__PURE__*/ W("<tr><td></td><td style=color:var(--text-muted)></td><td style=color:var(--text-muted)>"), zb = /*#__PURE__*/ W("<div class=search-bar><input class=search-input placeholder=\"Search everything...\">"), Bb = /*#__PURE__*/ W("<div class=loading-overlay><div class=spinner></div> Searching...");
function Vb(e) {
	let t = e.store, n = () => e.data.tables ?? [], r = () => e.data.objects.length + e.data.procedures.length + e.data.datawindows.length + n().length;
	return R(H, {
		get when() {
			return r() > 0;
		},
		get fallback() {
			return (() => {
				var e = Pb();
				return e.firstChild, e;
			})();
		},
		get children() {
			return [
				R(H, {
					get when() {
						return e.data.objects.length > 0;
					},
					get children() {
						var n = Ab(), r = n.firstChild, i = r.firstChild, a = i.firstChild.nextSibling;
						a.nextSibling;
						var o = r.nextSibling.firstChild.nextSibling;
						return X(i, () => e.data.objects.length, a), X(o, R(V, {
							get each() {
								return e.data.objects;
							},
							children: (e) => {
								let n = e.kind === "powerscript" ? "ps" : "dw";
								return (() => {
									var r = Fb(), i = r.firstChild, a = i.nextSibling, o = a.firstChild, s = a.nextSibling;
									return r.$$click = () => t.dispatch({
										tag: "objects",
										action: {
											tag: "select",
											name: e.name
										}
									}), X(i, () => e.name), q(o, `badge badge-${n}`), X(o, () => e.kind), X(s, () => za(e.file)), r;
								})();
							}
						})), n;
					}
				}),
				R(H, {
					get when() {
						return e.data.procedures.length > 0;
					},
					get children() {
						var n = jb(), r = n.firstChild, i = r.firstChild, a = i.firstChild.nextSibling;
						a.nextSibling;
						var o = r.nextSibling.firstChild.nextSibling;
						return X(i, () => e.data.procedures.length, a), X(o, R(V, {
							get each() {
								return e.data.procedures;
							},
							children: (e) => (() => {
								var n = Ib(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling, o = a.firstChild, s = a.nextSibling;
								return n.$$click = () => t.dispatch({
									tag: "objects",
									action: {
										tag: "proc-select",
										objectName: e.object,
										procName: e.name
									}
								}), X(r, () => e.object), X(i, () => e.name), X(o, () => e.proc_type), X(s, (() => {
									var t = U(() => !!e.start_line);
									return () => t() ? String(e.start_line) : "";
								})()), N(() => q(o, `badge ${Ra(e.proc_type)}`)), n;
							})()
						})), n;
					}
				}),
				R(H, {
					get when() {
						return e.data.datawindows.length > 0;
					},
					get children() {
						var n = Mb(), r = n.firstChild, i = r.firstChild, a = i.firstChild.nextSibling;
						a.nextSibling;
						var o = r.nextSibling.firstChild.nextSibling;
						return X(i, () => e.data.datawindows.length, a), X(o, R(V, {
							get each() {
								return e.data.datawindows;
							},
							children: (e) => (() => {
								var n = Lb(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
								return n.$$click = () => t.dispatch({
									tag: "datawindows",
									action: {
										tag: "select",
										name: e.dw_name
									}
								}), X(r, () => e.dw_name), X(i, () => e.control_name ?? "–"), X(a, () => e.control_type ?? ""), n;
							})()
						})), n;
					}
				}),
				R(H, {
					get when() {
						return n().length > 0;
					},
					get children() {
						var e = Nb(), r = e.firstChild, i = r.firstChild, a = i.firstChild.nextSibling;
						a.nextSibling;
						var o = r.nextSibling.firstChild.nextSibling;
						return X(i, () => n().length, a), X(o, R(V, {
							get each() {
								return n();
							},
							children: (e) => (() => {
								var n = Rb(), r = n.firstChild, i = r.nextSibling, a = i.nextSibling;
								return X(r, R(is, {
									get name() {
										return e.table_name;
									},
									store: t
								})), X(i, () => String(e.dw_count)), X(a, () => String(e.ps_count)), n;
							})()
						})), e;
					}
				})
			];
		}
	});
}
function Hb(e) {
	let t = e.store, n = t.getState(), r = () => n().search, [i, a] = j(r().term ?? "");
	ae(() => {
		t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: { view: "search" }
			}
		});
	});
	let o = Mo((e) => {
		e.length >= 2 && t.dispatch({
			tag: "search",
			action: {
				tag: "term",
				term: e
			}
		});
	}, 300);
	return [
		(() => {
			var e = zb(), n = e.firstChild;
			return n.$$keydown = (e) => {
				if (e.key === "Enter") {
					let e = i().trim();
					e.length >= 1 && t.dispatch({
						tag: "search",
						action: {
							tag: "term",
							term: e
						}
					});
				}
			}, n.$$input = (e) => {
				let t = e.currentTarget.value;
				a(t), o(t);
			}, N(() => n.value = i()), e;
		})(),
		R(H, {
			get when() {
				return r().loading;
			},
			get children() {
				return Bb();
			}
		}),
		R(H, {
			get when() {
				return r().results;
			},
			get children() {
				return R(Vb, {
					store: t,
					get data() {
						return r().results;
					}
				});
			}
		})
	];
}
G([
	"click",
	"input",
	"keydown"
]);
//#endregion
//#region src/components/detail/DetailShell.tsx
var Ub = /*#__PURE__*/ W("<div class=explore-right-body><div class=loading-overlay><div class=spinner></div> "), Wb = /*#__PURE__*/ W("<div class=explore-right-body><div class=tree-error>");
function Gb(e) {
	let t = () => {
		let t = e.entry;
		return !t || typeof t != "object" || "error" in t ? null : t;
	}, n = () => {
		let t = e.entry;
		return t && typeof t == "object" && "error" in t ? t.error : null;
	};
	return R(H, {
		get when() {
			return e.entry !== void 0;
		},
		get fallback() {
			return (() => {
				var t = Ub(), n = t.firstChild;
				return n.firstChild.nextSibling, X(n, () => e.loadingMsg, null), t;
			})();
		},
		get children() {
			return R(H, {
				get when() {
					return t();
				},
				get fallback() {
					return (() => {
						var e = Wb(), t = e.firstChild;
						return X(t, n), e;
					})();
				},
				children: (t) => e.children(t())
			});
		}
	});
}
//#endregion
//#region src/features/explore/DwDetailPanel.tsx
function Kb(e) {
	let t = ga(), n = t.getState(), r = () => n().explore.dwCache[e.nodeId], i = () => n().explore.dwLayoutCache[e.nodeId] ?? null;
	return R(Gb, {
		get entry() {
			return r();
		},
		loadingMsg: "Loading DataWindow...",
		children: (e) => R(Pf, {
			d: e,
			get layout() {
				return i();
			},
			store: t
		})
	});
}
//#endregion
//#region src/features/explore/ObjectsDetailPanel.tsx
var qb = /*#__PURE__*/ W("<div class=explore-empty>Select an object or DataWindow");
function Jb() {
	let e = ga().getState(), t = () => e().explore.selectedDw;
	return R(H, {
		get when() {
			return t();
		},
		get fallback() {
			return qb();
		},
		children: (e) => R(Kb, { get nodeId() {
			return e();
		} })
	});
}
//#endregion
//#region src/features/explore/Explore.tsx
function Yb(e) {
	return R(ha.Provider, {
		get value() {
			return e.store;
		},
		get children() {
			return R(Jb, {});
		}
	});
}
//#endregion
//#region src/components/ui/CopyButton.tsx
var Xb = /*#__PURE__*/ W("<button class=\"filter-pill copy-btn\">");
function Zb(e) {
	let [t, n] = j(!1);
	function r() {
		navigator.clipboard.writeText(e.text).then(() => {
			n(!0), setTimeout(() => n(!1), 1500);
		});
	}
	return (() => {
		var e = Xb();
		return e.$$click = r, X(e, () => t() ? "Copied!" : "Copy"), e;
	})();
}
G(["click"]);
//#endregion
//#region src/core/anonymize.ts
var Qb = "ABCDEFGHIJKLMNOPQRSTUVWXYZ", $b = "abcdefghijklmnopqrstuvwxyz", ex = "0123456789";
function tx(e) {
	return e[Math.floor(Math.random() * e.length)];
}
function nx(e) {
	let t = "";
	for (let n of e) n >= "A" && n <= "Z" ? t += tx(Qb) : n >= "a" && n <= "z" ? t += tx($b) : n >= "0" && n <= "9" ? t += tx(ex) : t += n;
	return t;
}
var rx = /\b[A-Za-z_][A-Za-z0-9_]*\b/g;
function ix(e) {
	let t = /* @__PURE__ */ new Map();
	return e.replace(rx, (e) => {
		if (il.has(e.toLowerCase())) return e;
		let n = t.get(e);
		return n === void 0 && (n = nx(e), t.set(e, n)), n;
	});
}
//#endregion
//#region src/features/errors/Errors.tsx
var ax = /*#__PURE__*/ W("<div style=text-align:center;padding:12px;color:var(--text-muted)>Loading..."), ox = /*#__PURE__*/ W("<div class=pagination style=display:flex;gap:8px;align-items:center;justify-content:center;margin-top:8px><button class=filter-pill>Prev</button><span style=font-size:12px;color:var(--text-muted)>Page <!> of <!> (<!> total)</span><button class=filter-pill>Next"), sx = /*#__PURE__*/ W("<div style=font-size:11px;color:var(--text-muted);margin-top:8px> error(s)"), cx = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Diagnostics</h2></div><div class=filter-pills><input class=search-input placeholder=\"Search message / file / snippet\"></div><table class=data-table><thead><tr><th>File</th><th>Kind</th><th>Line</th><th>Message</th></tr></thead><tbody>"), lx = /*#__PURE__*/ W("<button>"), ux = /*#__PURE__*/ W("<button class=link-btn title=\"Open source face\">"), dx = /*#__PURE__*/ W("<tr class=error-list-item><td class=name-cell></td><td></td><td></td><td>"), fx = /*#__PURE__*/ W("<span>"), px = /*#__PURE__*/ W("<div class=error-detail-header><p>"), mx = /*#__PURE__*/ W("<div class=card style=margin-top:16px>"), hx = /*#__PURE__*/ W("<div><div class=error-detail-header><p>Full file source — error at line "), gx = /*#__PURE__*/ W("<div class=loading-overlay><div class=spinner></div> Loading file source..."), _x = [
	{
		value: "all",
		label: "All"
	},
	{
		value: "powerscript",
		label: "PowerScript / Lex"
	},
	{
		value: "sql",
		label: "SQL"
	}
];
function vx(e) {
	let t = e.store, n = t.getState(), r = () => n().errors;
	ae(() => {
		t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: { view: "errors" }
			}
		}), t.dispatch({
			tag: "errors",
			action: { tag: "load" }
		});
	});
	function i(e) {
		t.dispatch({
			tag: "errors",
			action: {
				tag: "select",
				row: e
			}
		});
	}
	function a(e) {
		t.dispatch({
			tag: "objects",
			action: {
				tag: "select",
				name: e
			}
		});
	}
	let o = () => Math.max(1, Math.ceil(r().total / 100));
	return (() => {
		var e = cx(), n = e.firstChild.nextSibling, s = n.firstChild, c = n.nextSibling.firstChild.nextSibling;
		return X(n, R(V, {
			each: _x,
			children: (e) => (() => {
				var n = lx();
				return n.$$click = () => t.dispatch({
					tag: "errors",
					action: {
						tag: "setFilterKind",
						kind: e.value
					}
				}), X(n, () => e.label), N(() => q(n, `filter-pill ${r().filterKind === e.value ? "active" : ""}`)), n;
			})()
		}), s), s.$$input = (e) => t.dispatch({
			tag: "errors",
			action: {
				tag: "setQuery",
				query: e.currentTarget.value
			}
		}), X(c, R(H, {
			get when() {
				return !r().loading;
			},
			get children() {
				return R(V, {
					get each() {
						return r().items;
					},
					children: (e) => (() => {
						var t = dx(), n = t.firstChild, r = n.nextSibling, o = r.nextSibling, s = o.nextSibling;
						return t.$$click = () => i(e), X(n, R(H, {
							get when() {
								return e.object;
							},
							get fallback() {
								return (() => {
									var t = fx();
									return X(t, () => e.file), t;
								})();
							},
							get children() {
								var t = ux();
								return t.$$click = (t) => {
									t.stopPropagation(), a(e.object);
								}, X(t, () => e.file), t;
							}
						})), X(r, () => e.error_kind), X(o, () => e.line ?? ""), X(s, () => e.message), t;
					})()
				});
			}
		})), X(e, R(H, {
			get when() {
				return r().loading;
			},
			get children() {
				return ax();
			}
		}), null), X(e, R(H, {
			get when() {
				return r().total > 100;
			},
			get children() {
				var e = ox(), n = e.firstChild, i = n.nextSibling, a = i.firstChild.nextSibling, s = a.nextSibling.nextSibling, c = s.nextSibling.nextSibling;
				c.nextSibling;
				var l = i.nextSibling;
				return n.$$click = () => t.dispatch({
					tag: "errors",
					action: {
						tag: "setPage",
						page: r().page - 1
					}
				}), X(i, () => r().page + 1, a), X(i, o, s), X(i, () => r().total, c), l.$$click = () => t.dispatch({
					tag: "errors",
					action: {
						tag: "setPage",
						page: r().page + 1
					}
				}), N((e) => {
					var t = r().page === 0, i = r().page >= o() - 1;
					return t !== e.e && (n.disabled = e.e = t), i !== e.t && (l.disabled = e.t = i), e;
				}, {
					e: void 0,
					t: void 0
				}), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return U(() => r().total > 0)() && !r().loading;
			},
			get children() {
				var e = sx(), t = e.firstChild;
				return X(e, () => r().total, t), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return r().selected;
			},
			get children() {
				return (() => {
					let e = r().selected, t = e.error_kind === "sql" ? e.line ?? 1 : 1, n = () => e.snippet ?? e.message, i = F(() => ix(n())), a = F(() => ix(e.message)), o = e.error_kind === "sql";
					return (() => {
						var r = mx();
						return X(r, R(zh, {
							defaultValue: "raw",
							get children() {
								return [
									R(zh.List, {
										class: "tab-bar",
										get children() {
											return [
												R(zh.Trigger, {
													value: "raw",
													class: "tab-btn",
													children: "Raw"
												}),
												R(zh.Trigger, {
													value: "anonymized",
													class: "tab-btn",
													children: "Anonymized"
												}),
												U(() => o && R(zh.Trigger, {
													value: "file-context",
													class: "tab-btn",
													children: "File Context"
												}))
											];
										}
									}),
									R(zh.Content, {
										value: "raw",
										get children() {
											return [(() => {
												var t = px(), r = t.firstChild;
												return X(r, () => e.message), X(t, R(Zb, { get text() {
													return n();
												} }), null), t;
											})(), R(H, {
												get when() {
													return e.snippet;
												},
												get children() {
													return R(Cd, {
														get code() {
															return e.snippet;
														},
														baseLine: t,
														get highlightLine() {
															return e.line ?? void 0;
														}
													});
												}
											})];
										}
									}),
									R(zh.Content, {
										value: "anonymized",
										get children() {
											return [(() => {
												var e = px(), t = e.firstChild;
												return X(t, a), X(e, R(Zb, { get text() {
													return i();
												} }), null), e;
											})(), R(H, {
												get when() {
													return e.snippet;
												},
												get children() {
													return R(Cd, {
														get code() {
															return i();
														},
														baseLine: t,
														get highlightLine() {
															return e.line ?? void 0;
														}
													});
												}
											})];
										}
									}),
									U(() => o && R(zh.Content, {
										value: "file-context",
										get children() {
											return R(yx, { row: e });
										}
									}))
								];
							}
						})), r;
					})();
				})();
			}
		}), null), N(() => s.value = r().query), e;
	})();
}
function yx(e) {
	let [t] = re(() => e.row.file, (e) => fetch("/api/errors/source?file=" + encodeURIComponent(e)).then((e) => e.json()), { initialValue: { lines: [] } }), [n] = re(() => t()?.lines, (e) => !e || e.length === 0 ? Promise.resolve("") : nl(e.join("\n")), { initialValue: "" }), r = () => e.row.line ?? 1;
	return (() => {
		var e = hx(), t = e.firstChild.firstChild;
		return t.firstChild, X(t, r, null), X(e, R(H, {
			get when() {
				return U(() => !n.loading)() && n();
			},
			get fallback() {
				return gx();
			},
			get children() {
				return R(Cd, {
					get code() {
						return n();
					},
					baseLine: 1,
					get highlightLine() {
						return r();
					}
				});
			}
		}), null), e;
	})();
}
G(["input", "click"]);
//#endregion
//#region src/features/library/LibraryDetail.tsx
var bx = /*#__PURE__*/ W("<div class=error-banner>Failed to load library: "), xx = /*#__PURE__*/ W("<div class=card><div class=card-header><h2><span class=entity-icon></span> "), Sx = /*#__PURE__*/ W("<div style=margin-bottom:8px;color:var(--text-muted);font-size:13px> objects"), Cx = /*#__PURE__*/ W("<table class=data-table><thead><tr><th>Name</th><th>Kind</th><th>Procs</th></tr></thead><tbody>"), wx = /*#__PURE__*/ W("<div style=\"margin-top:16px;border-top:1px solid var(--border);padding-top:12px\"><table class=data-table><tbody><tr><td>Total procedures</td><td></td></tr><tr><td>Uncalled procedures</td><td><button class=link-btn>"), Tx = /*#__PURE__*/ W("<tr><td class=name-cell></td><td><span></span></td><td>");
function Ex(e) {
	let t = e.store, n = t.getState(), r = () => n().nav.route, i = () => {
		let e = r();
		return e.view === "libraryDetail" ? e.name : "";
	}, [a] = re(i, (e) => fetch(`/api/libraries/${encodeURIComponent(e)}`).then((e) => {
		if (!e.ok) throw Error(`${e.status}`);
		return e.json();
	}));
	function o(e, n) {
		n === "datawindow" ? t.dispatch({
			tag: "datawindows",
			action: {
				tag: "select",
				name: e
			}
		}) : t.dispatch({
			tag: "objects",
			action: {
				tag: "select",
				name: e
			}
		});
	}
	function s() {
		t.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: { view: "deadCode" }
			}
		});
	}
	return (() => {
		var e = xx(), t = e.firstChild.firstChild, n = t.firstChild;
		return n.nextSibling, X(n, R(ia, { size: 16 })), X(t, i, null), X(e, R(H, {
			get when() {
				return a.loading;
			},
			get children() {
				return R(os, {});
			}
		}), null), X(e, R(H, {
			get when() {
				return a.error;
			},
			get children() {
				var e = bx();
				return e.firstChild, X(e, () => String(a.error), null), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return a();
			},
			children: (e) => [
				(() => {
					var t = Sx(), n = t.firstChild;
					return X(t, () => e().object_count, n), t;
				})(),
				(() => {
					var t = Cx(), n = t.firstChild.nextSibling;
					return X(n, R(V, {
						get each() {
							return e().objects;
						},
						children: (e) => (() => {
							var t = Tx(), n = t.firstChild, r = n.nextSibling, i = r.firstChild, a = r.nextSibling;
							return X(n, R(mc, {
								get type() {
									return e.kind === "datawindow" ? "datawindow" : "object";
								},
								get name() {
									return e.name;
								},
								onClick: () => o(e.name, e.kind)
							})), X(i, () => e.kind), X(a, () => e.proc_count), N(() => q(i, `badge ${e.kind === "datawindow" ? "badge-dw" : e.kind === "powerscript" ? "badge-ps" : "badge-proj"}`)), t;
						})()
					})), t;
				})(),
				(() => {
					var t = wx(), n = t.firstChild.firstChild.firstChild, r = n.firstChild.nextSibling, i = n.nextSibling.firstChild.nextSibling.firstChild;
					return X(r, () => e().objects.reduce((e, t) => e + t.proc_count, 0)), i.$$click = s, X(i, () => e().uncalled_proc_count), t;
				})()
			]
		}), null), e;
	})();
}
G(["click"]);
//#endregion
//#region src/features/analysis/DeadCode.tsx
var Dx = /*#__PURE__*/ W("<button style=\"font-size:12px;padding:2px 10px\">"), Ox = /*#__PURE__*/ W("<span style=color:var(--text-muted);font-size:13px> procedure"), kx = /*#__PURE__*/ W("<div style=display:flex;gap:4px>"), Ax = /*#__PURE__*/ W("<div class=error-banner>Failed to load: "), jx = /*#__PURE__*/ W("<div style=\"color:var(--text-muted);font-size:13px;padding:8px 0\">No uncalled procedures found."), Mx = /*#__PURE__*/ W("<table class=data-table style=font-size:13px><thead><tr><th>Object</th><th>Procedure</th><th>Type</th><th>Confidence</th><th style=text-align:right>CC</th></tr></thead><tbody>"), Nx = /*#__PURE__*/ W("<div class=card><div class=card-header style=display:flex;align-items:center;gap:8px;flex-wrap:wrap><h2 style=flex:1>Dead Code"), Px = /*#__PURE__*/ W("<tr class=clickable><td style=color:var(--text-muted);font-size:12px></td><td><span class=entity-card-icon style=margin-right:4px></span></td><td><span></span></td><td><span></span></td><td style=text-align:right>"), Fx = /*#__PURE__*/ W("<span class=\"badge badge-cc\">"), Ix = /*#__PURE__*/ W("<span style=color:var(--text-muted)>–");
function Lx(e) {
	return e.caller_count_naive === 0 ? "high" : "medium";
}
function Rx(e) {
	let t = e.store, [n, r] = j("confidence"), [i] = re(() => fetch("/api/analysis/dead-code").then((e) => {
		if (!e.ok) throw Error(`${e.status}`);
		return e.json();
	})), a = () => {
		let e = i()?.items ?? [], t = n();
		return [...e].sort((e, n) => t === "confidence" ? (Lx(e) === "high" ? 0 : 1) - (Lx(n) === "high" ? 0 : 1) || (n.cyclomatic ?? -1) - (e.cyclomatic ?? -1) : t === "cc" ? (n.cyclomatic ?? -1) - (e.cyclomatic ?? -1) : t === "object" ? e.object.localeCompare(n.object) || e.name.localeCompare(n.name) : t === "name" ? e.name.localeCompare(n.name) : t === "type" ? e.proc_type.localeCompare(n.proc_type) || e.name.localeCompare(n.name) : 0);
	};
	function o(e) {
		return (() => {
			var t = Dx();
			return t.$$click = () => r(e.k), X(t, () => e.label), N(() => q(t, `filter-pill${n() === e.k ? " active" : ""}`)), t;
		})();
	}
	return (() => {
		var e = Nx(), n = e.firstChild;
		return n.firstChild, X(n, R(H, {
			get when() {
				return U(() => !!i())() && !i.loading;
			},
			get children() {
				return [(() => {
					var e = Ox(), t = e.firstChild;
					return X(e, () => i().total, t), X(e, () => i().total === 1 ? "" : "s", null), e;
				})(), (() => {
					var e = kx();
					return X(e, R(o, {
						k: "confidence",
						label: "Confidence"
					}), null), X(e, R(o, {
						k: "cc",
						label: "CC ↓"
					}), null), X(e, R(o, {
						k: "object",
						label: "Object"
					}), null), X(e, R(o, {
						k: "name",
						label: "Name"
					}), null), X(e, R(o, {
						k: "type",
						label: "Type"
					}), null), e;
				})()];
			}
		}), null), X(e, R(H, {
			get when() {
				return i.loading;
			},
			get children() {
				return R(os, {});
			}
		}), null), X(e, R(H, {
			get when() {
				return i.error;
			},
			get children() {
				var e = Ax();
				return e.firstChild, X(e, () => String(i.error), null), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return U(() => !!i())() && !i.loading;
			},
			get children() {
				return [R(H, {
					get when() {
						return i().total === 0;
					},
					get children() {
						return jx();
					}
				}), R(H, {
					get when() {
						return i().total > 0;
					},
					get children() {
						var e = Mx(), n = e.firstChild;
						n.firstChild.firstChild.nextSibling.nextSibling.nextSibling.nextSibling;
						var r = n.nextSibling;
						return X(r, R(V, {
							get each() {
								return a();
							},
							children: (e) => (() => {
								var n = Px(), r = n.firstChild, i = r.nextSibling, a = i.firstChild, o = i.nextSibling, s = o.firstChild, c = o.nextSibling, l = c.firstChild, u = c.nextSibling;
								return n.$$click = () => t.dispatch({
									tag: "objects",
									action: {
										tag: "proc-select",
										objectName: e.object,
										procName: e.name
									}
								}), X(r, () => e.object), X(a, R(Mi, { size: 13 })), X(i, () => e.name, null), X(s, () => e.proc_type), X(l, () => Lx(e)), X(u, (() => {
									var t = U(() => e.cyclomatic != null);
									return () => t() ? (() => {
										var t = Fx();
										return X(t, () => e.cyclomatic), t;
									})() : Ix();
								})()), N((t) => {
									var n = `badge badge-${Ra(e.proc_type)}`, r = `badge badge-${Lx(e)}`;
									return n !== t.e && q(s, t.e = n), r !== t.t && q(l, t.t = r), t;
								}, {
									e: void 0,
									t: void 0
								}), n;
							})()
						})), e;
					}
				})];
			}
		}), null), e;
	})();
}
G(["click"]);
//#endregion
//#region src/features/analysis/TaintExplorer.tsx
var zx = /*#__PURE__*/ W("<div class=error-banner>Failed to load taint paths: "), Bx = /*#__PURE__*/ W("<div style=margin-bottom:8px;color:var(--text-muted);font-size:13px> path<!> found"), Vx = /*#__PURE__*/ W("<table class=\"data-table taint-path-table\"><thead><tr><th>Severity</th><th>Category</th><th>Source</th><th>Sink</th><th>Steps</th></tr></thead><tbody>"), Hx = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Taint Explorer</h2></div><div class=taint-filters><label class=taint-filter-label>Source type<select class=taint-filter-select><option value>All</option><option value=db_read>DB read</option><option value=request_param>Request param</option></select></label><label class=taint-filter-label>Sink type<select class=taint-filter-select><option value>All</option><option value=db_write>DB write</option><option value=exec_immediate>EXECUTE IMMEDIATE</option></select></label><label class=taint-filter-label>Severity<select class=taint-filter-select><option value>All</option><option value=critical>Critical</option><option value=high>High</option><option value=medium>Medium</option><option value=low>Low"), Ux = /*#__PURE__*/ W("<div class=taint-empty>No taint paths found under current filters.<br>This does not constitute a formal proof of absence — P4 formal verification is required for that guarantee."), Wx = /*#__PURE__*/ W("<span class=taint-line>:"), Gx = /*#__PURE__*/ W("<tr class=clickable><td><span></span></td><td></td><td class=taint-endpoint><span class=taint-proc>.</span><span class=taint-type-label></span></td><td class=taint-endpoint><span class=taint-proc>.</span><span class=taint-type-label></span></td><td><span class=trace-nav-link>View "), Kx = {
	critical: 0,
	high: 1,
	medium: 2,
	low: 3
};
function qx(e) {
	let [t, n] = j(""), [r, i] = j(""), [a, o] = j(""), [s] = re(() => `${t()}|${r()}|${a()}`, async () => {
		let e = new URLSearchParams();
		t() && e.set("source_type", t()), r() && e.set("sink_type", r()), a() && e.set("severity", a());
		let n = await fetch("/api/analysis/taint-paths?" + e.toString());
		if (!n.ok) throw Error(`HTTP ${n.status}`);
		return n.json();
	});
	function c(t) {
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "taintPathView",
					pathId: t
				}
			}
		});
	}
	let l = () => [...s()?.paths ?? []].sort((e, t) => (Kx[e.severity] ?? 9) - (Kx[t.severity] ?? 9));
	return (() => {
		var e = Hx(), u = e.firstChild.nextSibling.firstChild, d = u.firstChild.nextSibling, f = u.nextSibling, p = f.firstChild.nextSibling, m = f.nextSibling.firstChild.nextSibling;
		return d.$$input = (e) => n(e.currentTarget.value), p.$$input = (e) => i(e.currentTarget.value), m.$$input = (e) => o(e.currentTarget.value), X(e, R(H, {
			get when() {
				return s.loading;
			},
			get children() {
				return R(os, {});
			}
		}), null), X(e, R(H, {
			get when() {
				return s.error;
			},
			get children() {
				var e = zx();
				return e.firstChild, X(e, () => String(s.error), null), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return U(() => !s.loading && !s.error)() && s();
			},
			get children() {
				return [(() => {
					var e = Bx(), t = e.firstChild, n = t.nextSibling;
					return n.nextSibling, X(e, () => s().total, t), X(e, () => s().total === 1 ? "" : "s", n), e;
				})(), R(H, {
					get when() {
						return l().length > 0;
					},
					get fallback() {
						return Ux();
					},
					get children() {
						var e = Vx(), t = e.firstChild.nextSibling;
						return X(t, R(V, {
							get each() {
								return l();
							},
							children: (e) => (() => {
								var t = Gx(), n = t.firstChild, r = n.firstChild, i = n.nextSibling, a = i.nextSibling, o = a.firstChild, s = o.firstChild, l = o.nextSibling, u = a.nextSibling, d = u.firstChild, f = d.firstChild, p = d.nextSibling, m = u.nextSibling.firstChild;
								return m.firstChild, t.$$click = () => c(e.id), X(r, () => e.severity), X(i, () => e.category), X(o, () => e.source.object, s), X(o, () => e.source.proc, null), X(a, R(H, {
									get when() {
										return e.source.line != null;
									},
									get children() {
										var t = Wx();
										return t.firstChild, X(t, () => e.source.line, null), t;
									}
								}), l), X(l, () => e.source.type), X(d, () => e.sink.object, f), X(d, () => e.sink.proc, null), X(u, R(H, {
									get when() {
										return e.sink.line != null;
									},
									get children() {
										var t = Wx();
										return t.firstChild, X(t, () => e.sink.line, null), t;
									}
								}), p), X(p, () => e.sink.type), X(m, R(fi, {
									size: 12,
									style: { "vertical-align": "middle" }
								}), null), N(() => q(r, `badge badge-severity-${e.severity}`)), t;
							})()
						})), e;
					}
				})];
			}
		}), null), N(() => d.value = t()), N(() => p.value = r()), N(() => m.value = a()), e;
	})();
}
G(["input", "click"]);
//#endregion
//#region src/features/analysis/AnalysisView.tsx
var Jx = /*#__PURE__*/ W("<div class=analysis-view><div class=analysis-title-bar><span class=analysis-title></span><span class=analysis-context-label></span><button class=analysis-save-btn title=\"Save this view (not yet implemented)\">Save this view</button></div><div class=analysis-phase-footer>"), Yx = /*#__PURE__*/ W("<button class=analysis-assumptions-toggle><span></span> Assumptions"), Xx = /*#__PURE__*/ W("<p class=analysis-assumptions-body>");
function Zx(e) {
	let [t, n] = j(!1);
	return (() => {
		var r = Jx(), i = r.firstChild, a = i.firstChild, o = a.nextSibling, s = i.nextSibling;
		return X(a, () => e.title), X(o, () => e.contextLabel), X(r, () => e.children, s), X(s, (() => {
			var r = U(() => !!e.assumptions);
			return () => r() && [(() => {
				var e = Yx(), r = e.firstChild;
				return e.$$click = () => n((e) => !e), X(r, (() => {
					var e = U(() => !!t());
					return () => e() ? R(bi, { size: 12 }) : R(wi, { size: 12 });
				})()), N(() => K(e, "aria-expanded", t())), e;
			})(), U(() => U(() => !!t())() && (() => {
				var t = Xx();
				return X(t, () => e.assumptions), t;
			})())];
		})()), r;
	})();
}
G(["click"]);
//#endregion
//#region src/features/analysis/LinearTrace.tsx
var Qx = /*#__PURE__*/ W("<div class=trace-path-nav><button class=icon-btn title=\"Previous path\"></button><span class=trace-path-counter>Path <!> of </span><button class=icon-btn title=\"Next path\">"), $x = /*#__PURE__*/ W("<div class=trace-collapse-toggle data-testid=trace-collapse-toggle> <!> intermediate step<!> — click to expand (or press E)"), eS = /*#__PURE__*/ W("<div class=linear-trace><div class=linear-trace-layout><div class=linear-trace-steps>"), tS = /*#__PURE__*/ W("<span class=trace-step-line>:"), nS = /*#__PURE__*/ W("<div class=trace-step-annotation>via "), rS = /*#__PURE__*/ W("<div class=linear-trace-step data-testid=trace-step><div class=trace-step-left-border></div><div class=trace-step-body><div class=trace-step-header><span class=trace-step-num></span><span></span><button class=\"trace-step-proc link-btn\">.</button></div><div class=trace-step-stmt>"), iS = /*#__PURE__*/ W("<div class=trace-callgraph data-testid=trace-callgraph><div class=\"trace-callgraph-label section-label\">Procedures traversed</div><div class=trace-callgraph-chain>"), aS = /*#__PURE__*/ W("<span class=trace-callgraph-arrow>"), oS = /*#__PURE__*/ W("<button class=\"trace-callgraph-proc link-btn\">");
function sS(e, t) {
	return t === "slice-backward" ? "AFFECTED" : t === "slice-forward" ? "AFFECTING" : e === "source" ? "SOURCE" : e === "sink" ? "SINK" : "TRANSFORM";
}
function cS(e, t) {
	return t === "slice-backward" ? "badge step-badge step-badge-affected" : t === "slice-forward" ? "badge step-badge step-badge-affecting" : e === "source" ? "badge step-badge step-badge-source" : e === "sink" ? "badge step-badge step-badge-sink" : "badge step-badge step-badge-transform";
}
var lS = 4, uS = 4, dS = 20;
function fS(e, t) {
	if (e.length <= dS || t) return {
		visible: e.map((e, t) => ({
			index: t,
			step: e
		})),
		hiddenCount: 0
	};
	let n = e.slice(0, lS).map((e, t) => ({
		index: t,
		step: e
	})), r = e.slice(-4).map((t, n) => ({
		index: e.length - uS + n,
		step: t
	}));
	return {
		visible: [...n, ...r],
		hiddenCount: e.length - lS - uS
	};
}
function pS(e) {
	let [t, n] = j(!1);
	ae(() => {
		function t(t) {
			let r = t.target;
			r.tagName === "INPUT" || r.tagName === "TEXTAREA" || r.isContentEditable || ((t.key === "e" || t.key === "E") && (t.preventDefault(), n(!0)), t.key === "ArrowLeft" && e.onPrevPath && (t.preventDefault(), e.onPrevPath()), t.key === "ArrowRight" && e.onNextPath && (t.preventDefault(), e.onNextPath()));
		}
		document.addEventListener("keydown", t), L(() => document.removeEventListener("keydown", t));
	});
	let r = () => fS(e.steps, t());
	return (() => {
		var i = eS(), a = i.firstChild, o = a.firstChild;
		return X(i, R(H, {
			get when() {
				return (e.totalPaths ?? 0) > 1;
			},
			get children() {
				var t = Qx(), n = t.firstChild, r = n.nextSibling, i = r.firstChild.nextSibling;
				i.nextSibling;
				var a = r.nextSibling;
				return n.$$click = () => e.onPrevPath?.(), X(n, R(Si, { size: 14 })), X(r, () => (e.pathIndex ?? 0) + 1, i), X(r, () => e.totalPaths, null), a.$$click = () => e.onNextPath?.(), X(a, R(wi, { size: 14 })), N((t) => {
					var r = (e.pathIndex ?? 0) === 0, i = (e.pathIndex ?? 0) >= (e.totalPaths ?? 1) - 1;
					return r !== t.e && (n.disabled = t.e = r), i !== t.t && (a.disabled = t.t = i), t;
				}, {
					e: void 0,
					t: void 0
				}), t;
			}
		}), a), X(o, R(V, {
			get each() {
				return r().visible.slice(0, e.steps.length <= dS || t() ? void 0 : lS);
			},
			children: ({ index: t, step: n }) => R(mS, {
				stepNum: t + 1,
				step: n,
				get traceType() {
					return e.traceType;
				},
				get onNavigate() {
					return e.onNavigateToProc;
				}
			})
		}), null), X(o, R(H, {
			get when() {
				return r().hiddenCount > 0;
			},
			get children() {
				var e = $x(), t = e.firstChild, i = t.nextSibling, a = i.nextSibling.nextSibling;
				return a.nextSibling, e.$$click = () => n(!0), X(e, R(wi, { size: 12 }), t), X(e, () => r().hiddenCount, i), X(e, () => r().hiddenCount === 1 ? "" : "s", a), e;
			}
		}), null), X(o, R(H, {
			get when() {
				return U(() => !t())() && r().hiddenCount > 0;
			},
			get children() {
				return R(V, {
					get each() {
						return r().visible.slice(lS);
					},
					children: ({ index: t, step: n }) => R(mS, {
						stepNum: t + 1,
						step: n,
						get traceType() {
							return e.traceType;
						},
						get onNavigate() {
							return e.onNavigateToProc;
						}
					})
				});
			}
		}), null), X(a, R(H, {
			get when() {
				return e.traversedProcs.length > 0;
			},
			get children() {
				return R(hS, {
					get procs() {
						return e.traversedProcs;
					},
					get onNavigate() {
						return e.onNavigateToProc;
					}
				});
			}
		}), null), i;
	})();
}
function mS(e) {
	let t = e.step;
	return (() => {
		var n = rS(), r = n.firstChild.nextSibling, i = r.firstChild, a = i.firstChild, o = a.nextSibling, s = o.nextSibling, c = s.firstChild, l = i.nextSibling;
		return X(a, () => e.stepNum), X(o, () => sS(t.step_kind, e.traceType)), s.$$click = () => e.onNavigate?.(t.object, t.proc_name, t.line ?? void 0), X(s, () => t.object, c), X(s, () => t.proc_name, null), X(i, R(H, {
			get when() {
				return t.line != null;
			},
			get children() {
				var e = tS();
				return e.firstChild, X(e, () => t.line, null), e;
			}
		}), null), X(l, () => t.description), X(r, R(H, {
			get when() {
				return t.var_name;
			},
			get children() {
				var e = nS();
				return e.firstChild, X(e, () => t.var_name, null), e;
			}
		}), null), N(() => q(o, cS(t.step_kind, e.traceType))), n;
	})();
}
function hS(e) {
	return (() => {
		var t = iS(), n = t.firstChild.nextSibling;
		return X(n, R(V, {
			get each() {
				return e.procs;
			},
			children: (t, n) => [R(H, {
				get when() {
					return n() > 0;
				},
				get children() {
					var e = aS();
					return X(e, R(fi, { size: 12 })), e;
				}
			}), R(gS, {
				procKey: t,
				get onNavigate() {
					return e.onNavigate;
				}
			})]
		})), t;
	})();
}
function gS(e) {
	let t = () => {
		let t = e.procKey.indexOf(".");
		return t === -1 ? {
			object: "",
			proc: e.procKey
		} : {
			object: e.procKey.slice(0, t),
			proc: e.procKey.slice(t + 1)
		};
	};
	return (() => {
		var n = oS();
		return n.$$click = () => {
			let { object: n, proc: r } = t();
			e.onNavigate?.(n, r);
		}, X(n, () => t().proc), N(() => K(n, "title", e.procKey)), n;
	})();
}
G(["click"]);
//#endregion
//#region src/features/analysis/TaintPathView.tsx
var _S = /*#__PURE__*/ W("<div class=error-banner>Failed to load taint path <!>: "), vS = /*#__PURE__*/ W("<span class=trace-step-line> :"), yS = /*#__PURE__*/ W("<div class=\"taint-path-meta card\"><div class=taint-meta-row><span class=section-label>Source</span><span class=taint-meta-val>.<span class=\"badge badge-muted\"style=margin-left:6px></span></span></div><div class=taint-meta-row><span class=section-label>Sink</span><span class=taint-meta-val>.<span class=\"badge badge-muted\"style=margin-left:6px></span></span></div><div class=taint-meta-row><span class=section-label>Severity</span><span></span></div><div class=taint-meta-row><span class=section-label>Category</span><span class=taint-meta-val>");
function bS(e) {
	let t = e.store.getState(), n = () => {
		let e = t().nav.route;
		return e.view === "taintPathView" ? e.pathId : 0;
	}, [r] = re(n, async (e) => {
		let t = await fetch(`/api/analysis/taint-paths/${e}`);
		if (!t.ok) throw Error(`HTTP ${t.status}`);
		return t.json();
	});
	function i(t, n, r) {
		e.store.dispatch({
			tag: "objects",
			action: {
				tag: "proc-select",
				objectName: t,
				procName: n
			}
		});
	}
	function a() {
		let t = n();
		t <= 1 || e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "taintPathView",
					pathId: t - 1
				}
			}
		});
	}
	function o() {
		let t = n();
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "taintPathView",
					pathId: t + 1
				}
			}
		});
	}
	let s = () => {
		let e = r();
		return e ? `${e.source.object}.${e.source.proc} → ${e.sink.object}.${e.sink.proc}` : `Taint Path ${n()}`;
	}, c = () => {
		let e = r();
		return e ? `${e.category} · ${e.severity} severity` : "";
	};
	return R(Zx, {
		get title() {
			return s();
		},
		get contextLabel() {
			return c();
		},
		assumptions: "Taint propagation is context-insensitive: the same procedure is not split by call site. Dynamic dispatch is not resolved. Analysis covers intra-procedural def-use chains and inter-procedural argument/return flow.",
		get children() {
			return [
				R(H, {
					get when() {
						return r.loading;
					},
					get children() {
						return R(os, {});
					}
				}),
				R(H, {
					get when() {
						return r.error;
					},
					get children() {
						var e = _S(), t = e.firstChild.nextSibling;
						return t.nextSibling, X(e, n, t), X(e, () => String(r.error), null), e;
					}
				}),
				R(H, {
					get when() {
						return U(() => !r.loading && !r.error)() && r();
					},
					children: (e) => [(() => {
						var t = yS(), n = t.firstChild, r = n.firstChild.nextSibling, i = r.firstChild, a = i.nextSibling, o = n.nextSibling, s = o.firstChild.nextSibling, c = s.firstChild, l = c.nextSibling, u = o.nextSibling, d = u.firstChild.nextSibling, f = u.nextSibling.firstChild.nextSibling;
						return X(r, () => e().source.object, i), X(r, () => e().source.proc, a), X(r, R(H, {
							get when() {
								return e().source.line != null;
							},
							get children() {
								var t = vS();
								return t.firstChild, X(t, () => e().source.line, null), t;
							}
						}), a), X(a, () => e().source.type), X(s, () => e().sink.object, c), X(s, () => e().sink.proc, l), X(s, R(H, {
							get when() {
								return e().sink.line != null;
							},
							get children() {
								var t = vS();
								return t.firstChild, X(t, () => e().sink.line, null), t;
							}
						}), l), X(l, () => e().sink.type), X(d, () => e().severity), X(f, () => e().category), N(() => q(d, `badge badge-severity-${e().severity}`)), t;
					})(), R(pS, {
						get steps() {
							return e().steps;
						},
						traceType: "taint",
						get traversedProcs() {
							return xS(e().steps);
						},
						onPrevPath: a,
						onNextPath: o,
						onNavigateToProc: i
					})]
				})
			];
		}
	});
}
function xS(e) {
	let t = /* @__PURE__ */ new Set(), n = [];
	for (let r of e) {
		let e = `${r.object}.${r.proc_name}`;
		t.has(e) || (t.add(e), n.push(e));
	}
	return n;
}
//#endregion
//#region src/features/analysis/SliceView.tsx
var SS = /*#__PURE__*/ W("<div class=error-banner>Failed to compute slice: "), CS = /*#__PURE__*/ W("<div class=empty-state style=padding:24px;color:var(--text-muted)>No statements in slice. This may mean the variable is not used/defined beyond this point.");
function wS(e) {
	let t = e.store.getState(), n = () => {
		let e = t().nav.route;
		return e.view === "sliceView" ? {
			object: e.object,
			proc: e.proc,
			line: e.line,
			direction: e.direction
		} : null;
	}, [r] = re(() => {
		let e = n();
		return e ? `${e.object}::${e.proc}::${e.line}::${e.direction}` : null;
	}, async () => {
		let e = n();
		if (!e) throw Error("No route params");
		let t = `/api/analysis/slice/${encodeURIComponent(e.object)}/${encodeURIComponent(e.proc)}/${e.line}?direction=${e.direction}`, r = await fetch(t);
		if (!r.ok) throw Error(`HTTP ${r.status}`);
		return r.json();
	});
	function i(t, n, r) {
		e.store.dispatch({
			tag: "objects",
			action: {
				tag: "proc-select",
				objectName: t,
				procName: n
			}
		});
	}
	let a = () => n()?.direction === "forward" ? "slice-forward" : "slice-backward", o = () => {
		let e = n();
		return e ? `${e.direction === "forward" ? "Forward" : "Backward"} Slice — ${e.object}.${e.proc} (line ${e.line})` : "Slice";
	}, s = () => {
		let e = r();
		return e ? `${e.steps.length} statement${e.steps.length === 1 ? "" : "s"}` : "";
	}, c = () => (r()?.steps ?? []).map((e) => ({
		object: e.object,
		proc_name: e.proc,
		line: e.line,
		var_name: e.var,
		step_kind: e.kind,
		description: e.text
	}));
	return R(Zx, {
		get title() {
			return o();
		},
		get contextLabel() {
			return s();
		},
		assumptions: "Slice is computed context-insensitively. The slice may include statements reachable through dynamic dispatch that cannot be statically resolved.",
		get children() {
			return [
				R(H, {
					get when() {
						return r.loading;
					},
					get children() {
						return R(os, {});
					}
				}),
				R(H, {
					get when() {
						return r.error;
					},
					get children() {
						var e = SS();
						return e.firstChild, X(e, () => String(r.error), null), e;
					}
				}),
				R(H, {
					get when() {
						return U(() => !r.loading && !r.error)() && r();
					},
					children: (e) => R(H, {
						get when() {
							return e().steps.length > 0;
						},
						get fallback() {
							return CS();
						},
						get children() {
							return R(pS, {
								get steps() {
									return c();
								},
								get traceType() {
									return a();
								},
								get traversedProcs() {
									return e().procedures_traversed;
								},
								onNavigateToProc: i
							});
						}
					})
				})
			];
		}
	});
}
//#endregion
//#region src/features/analysis/FormalReports.tsx
var TS = /*#__PURE__*/ W("<div class=card><div class=card-header><h2>Formal Verification</h2></div><div style=padding:16px;color:var(--text-muted);font-size:13px>Z3-backed formal verification is not yet available. When built, this view will present proved invariants, counterexamples, and proof certificates filterable by claim type and verdict.");
function ES(e) {
	return (() => {
		var e = TS();
		return e.firstChild.nextSibling, e;
	})();
}
//#endregion
//#region src/features/analysis/CFGDiagram.tsx
function DS(e) {
	let t = e.store.getState(), n = () => {
		let e = t().nav.route;
		return e.view === "cfgDiagram" ? e.object : "";
	}, r = () => {
		let e = t().nav.route;
		return e.view === "cfgDiagram" ? e.proc : "";
	};
	function i() {
		e.store.dispatch({
			tag: "nav",
			action: {
				tag: "navigate",
				route: {
					view: "procedureDetail",
					name: n(),
					proc: r()
				}
			}
		});
	}
	return R(Zx, {
		get title() {
			return `${n()}.${r()}`;
		},
		contextLabel: "Control Flow Graph",
		assumptions: "CFG is constructed from the parsed AST body. Loop back-edges and exception paths are approximated. Dynamic dispatch is not resolved.",
		get children() {
			return R(_u, {
				get object() {
					return n();
				},
				get proc() {
					return r();
				},
				get store() {
					return e.store;
				},
				onGoto: i
			});
		}
	});
}
//#endregion
//#region src/components/windows/WindowControls.tsx
var OS = /*#__PURE__*/ W("<div class=wm-controls><button class=wm-control-btn title=Minimize></button><button class=\"wm-control-btn wm-control-close\"title=Close>"), kS = /*#__PURE__*/ W("<button class=wm-control-btn title=Restore>"), AS = /*#__PURE__*/ W("<button class=wm-control-btn title=Maximize>");
function jS(e) {
	return (() => {
		var t = OS(), n = t.firstChild, r = n.nextSibling;
		return J(n, "click", e.onMinimize, !0), X(n, R(ea, { size: 12 })), X(t, (() => {
			var t = U(() => !!e.maximized);
			return () => t() ? (() => {
				var t = kS();
				return J(t, "click", e.onRestore, !0), X(t, R(Qi, { size: 12 })), t;
			})() : (() => {
				var t = AS();
				return J(t, "click", e.onMaximize, !0), X(t, R(Ji, { size: 12 })), t;
			})();
		})(), r), J(r, "click", e.onClose, !0), X(r, R(ma, { size: 12 })), t;
	})();
}
G(["click"]);
//#endregion
//#region src/components/windows/WindowFrame.tsx
var MS = /*#__PURE__*/ W("<div><div><span class=wm-title></span></div><div class=wm-content>"), NS = /*#__PURE__*/ W("<div>"), PS = 200, FS = 150;
function IS(e) {
	let [t, n] = j(!1), [r, i] = j(!1), a = 0, o = 0, s = 0, c = 0;
	function l(t) {
		e.store.dispatch({
			tag: "windowManager",
			action: t
		});
	}
	function u(t) {
		t.preventDefault(), n(!0), a = t.clientX, o = t.clientY, s = e.win.x, c = e.win.y, document.addEventListener("pointermove", d), document.addEventListener("pointerup", f);
	}
	function d(t) {
		let n = t.clientX - a, r = t.clientY - o;
		l({
			tag: "move-window",
			id: e.win.id,
			x: s + n,
			y: c + r
		});
	}
	function f() {
		n(!1), document.removeEventListener("pointermove", d), document.removeEventListener("pointerup", f);
	}
	L(() => {
		document.removeEventListener("pointermove", d), document.removeEventListener("pointerup", f);
	});
	let p = 0, m = 0, h = 0, g = 0;
	function _(t) {
		t.preventDefault(), t.stopPropagation(), i(!0), p = t.clientX, m = t.clientY, h = e.win.width, g = e.win.height, document.addEventListener("pointermove", v), document.addEventListener("pointerup", y);
	}
	function v(t) {
		let n = t.clientX - p, r = t.clientY - m;
		l({
			tag: "resize-window",
			id: e.win.id,
			width: Math.max(PS, h + n),
			height: Math.max(FS, g + r)
		});
	}
	function y() {
		i(!1), document.removeEventListener("pointermove", v), document.removeEventListener("pointerup", y);
	}
	L(() => {
		document.removeEventListener("pointermove", v), document.removeEventListener("pointerup", y);
	});
	function b() {
		e.isActive || l({
			tag: "focus-window",
			id: e.win.id
		});
	}
	let x = () => e.win.maximized ? {
		left: "0px",
		top: "0px",
		width: "100%",
		height: "100%",
		"z-index": e.win.zIndex
	} : {
		left: `${e.win.x}px`,
		top: `${e.win.y}px`,
		width: `${e.win.width}px`,
		height: `${e.win.height}px`,
		"z-index": e.win.zIndex
	};
	return (() => {
		var n = MS(), i = n.firstChild, a = i.firstChild, o = i.nextSibling;
		return n.$$pointerdown = b, i.$$pointerdown = u, X(a, () => e.win.title), X(i, R(jS, {
			get minimized() {
				return e.win.minimized;
			},
			get maximized() {
				return e.win.maximized;
			},
			onMinimize: () => l({
				tag: "minimize-window",
				id: e.win.id
			}),
			onMaximize: () => l({
				tag: "maximize-window",
				id: e.win.id
			}),
			onRestore: () => l({
				tag: "restore-window",
				id: e.win.id
			}),
			onClose: () => l({
				tag: "close-window",
				id: e.win.id
			})
		}), null), X(o, () => e.children), X(n, (() => {
			var t = U(() => !e.win.maximized);
			return () => t() && (() => {
				var e = NS();
				return e.$$pointerdown = _, N(() => q(e, `wm-resize-handle${r() ? " active" : ""}`)), e;
			})();
		})(), null), N((r) => {
			var a = `wm-window${e.isActive ? " active" : ""}${e.win.minimized ? " minimized" : ""}${e.win.maximized ? " maximized" : ""}`, o = x(), s = `wm-titlebar${t() ? " dragging" : ""}`;
			return a !== r.e && q(n, r.e = a), r.t = ct(n, o, r.t), s !== r.a && q(i, r.a = s), r;
		}, {
			e: void 0,
			t: void 0,
			a: void 0
		}), n;
	})();
}
G(["pointerdown"]);
//#endregion
//#region src/components/windows/WindowRuntimeView.tsx
var LS = /*#__PURE__*/ W("<div class=runtime-ctrl>"), RS = /*#__PURE__*/ W("<div style=font-size:9px;color:var(--text-muted);margin-top:2px>[<!>]"), zS = /*#__PURE__*/ W("<div style=font-size:9px>"), BS = /*#__PURE__*/ W("<div class=runtime-control style=\"position:absolute;left:0;top:0;width:100%;height:100%;border:1px solid var(--border);padding:2px 4px;font-size:10px;cursor:pointer;box-sizing:border-box;color:var(--text-muted)\"><span style=font-weight:600;color:var(--text)>"), VS = /*#__PURE__*/ W("<div class=card style=\"margin-top:8px;padding:8px 12px\"><div style=font-size:11px;font-weight:600;margin-bottom:4px;color:var(--text-muted)>Runtime State</div><table class=data-table style=font-size:11px><tbody>"), HS = /*#__PURE__*/ W("<tr><td style=color:var(--text-muted);padding-right:12px></td><td>"), US = /*#__PURE__*/ W("<div style=color:var(--text-muted);font-size:13px>Loading window…"), WS = /*#__PURE__*/ W("<div style=color:var(--error);font-size:13px>Error: "), GS = /*#__PURE__*/ W("<div class=runtime-view>"), KS = .08;
function qS(e) {
	return {
		position: "absolute",
		left: `${e.x * KS}px`,
		top: `${e.y * KS}px`,
		width: `${e.width * KS}px`,
		height: `${e.height * KS}px`,
		overflow: "hidden"
	};
}
function JS(e, t) {
	let n = e.type.toLowerCase();
	return n === "statictext" ? (() => {
		var t = LS();
		return X(t, R(yu, { ctrl: e })), N((n) => ct(t, qS(e), n)), t;
	})() : n === "commandbutton" ? (() => {
		var n = LS();
		return X(n, R(xu, {
			ctrl: e,
			onClick: t
		})), N((t) => ct(n, qS(e), t)), n;
	})() : n === "groupbox" ? (() => {
		var t = LS();
		return X(t, R(Cu, { ctrl: e })), N((n) => ct(t, qS(e), n)), t;
	})() : n === "singlelineedit" || n === "multilineedit" ? (() => {
		var t = LS();
		return X(t, R(Eu, { ctrl: e })), N((n) => ct(t, qS(e), n)), t;
	})() : (() => {
		var n = LS();
		return X(n, R(YS, {
			ctrl: e,
			onClick: t
		})), N((t) => ct(n, qS(e), t)), n;
	})();
}
function YS(e) {
	let t = () => e.ctrl.type.toLowerCase().includes("dw") || e.ctrl.name.startsWith("dw_");
	return (() => {
		var n = BS(), r = n.firstChild;
		return J(n, "click", e.onClick, !0), X(r, () => e.ctrl.name), X(n, R(H, {
			get when() {
				return t();
			},
			get children() {
				var t = RS(), n = t.firstChild.nextSibling;
				return n.nextSibling, X(t, () => e.ctrl.dataobject ?? e.ctrl.properties?.dataobject ?? "DataWindow", n), t;
			}
		}), null), X(n, R(H, {
			get when() {
				return U(() => !!e.ctrl.text)() && !t();
			},
			get children() {
				var t = zS();
				return X(t, () => e.ctrl.text), t;
			}
		}), null), N((r) => {
			var i = t() ? "var(--surface)" : "var(--surface-raised)", a = `${e.ctrl.name} (${e.ctrl.type})`;
			return i !== r.e && Y(n, "background", r.e = i), a !== r.t && K(n, "title", r.t = a), r;
		}, {
			e: void 0,
			t: void 0
		}), n;
	})();
}
function XS(e) {
	let t = () => Object.entries(e.variables);
	return R(H, {
		get when() {
			return t().length > 0;
		},
		get children() {
			var e = VS(), n = e.firstChild.nextSibling.firstChild;
			return X(n, R(V, {
				get each() {
					return t();
				},
				children: ([e, t]) => (() => {
					var n = HS(), r = n.firstChild, i = r.nextSibling;
					return X(r, e), X(i, () => String(t)), n;
				})()
			})), e;
		}
	});
}
function ZS(e) {
	let t = e.store.getState(), n = () => t().runtimes[e.windowId] ?? lr, r = () => n().layout, i = () => n().controlValues, a = () => nr(n().varEnv), o = (t) => {
		e.store.dispatch({
			tag: "runtime",
			windowId: e.windowId,
			action: {
				tag: "control-click",
				controlName: t.name
			}
		});
	};
	return (() => {
		var e = GS();
		return X(e, R(H, {
			get when() {
				return !n().ast;
			},
			get children() {
				return US();
			}
		}), null), X(e, R(H, {
			get when() {
				return n().error;
			},
			get children() {
				var e = WS();
				return e.firstChild, X(e, () => n().error, null), e;
			}
		}), null), X(e, R(H, {
			get when() {
				return r();
			},
			children: (e) => [R(Fu, {
				get naturalWidth() {
					return e().width;
				},
				get naturalHeight() {
					return e().height;
				},
				baseScale: KS,
				get children() {
					return R(V, {
						get each() {
							return e().controls;
						},
						children: (t) => {
							if (t.type.toLowerCase().includes("datawindow") || t.name === "dw" || t.name.startsWith("dw_")) {
								let n = t.height > 0 ? t.height : e().height - t.y, r = {
									...qS(t),
									height: `${n * KS}px`
								};
								return (() => {
									var e = LS();
									return X(e, R(H, {
										get when() {
											return i()[t.name];
										},
										get fallback() {
											return R(YS, {
												ctrl: t,
												onClick: () => o(t)
											});
										},
										children: (e) => R(Nu, { get data() {
											return e();
										} })
									})), N((t) => ct(e, r, t)), e;
								})();
							}
							return JS(t, () => o(t));
						}
					});
				}
			}), R(XS, { get variables() {
				return a();
			} })]
		}), null), e;
	})();
}
G(["click"]);
//#endregion
//#region src/components/windows/Desktop.tsx
var QS = /*#__PURE__*/ W("<div class=wm-desktop-empty>No windows open. Launch an application to get started."), $S = /*#__PURE__*/ W("<div class=wm-desktop>");
function eC(e) {
	let t = e.store.getState(), n = () => t().windowManager.windows, r = () => t().windowManager.activeWindowId;
	return (() => {
		var t = $S();
		return X(t, R(H, {
			get when() {
				return n().length === 0;
			},
			get children() {
				return QS();
			}
		}), null), X(t, R(V, {
			get each() {
				return n();
			},
			children: (t) => R(IS, {
				win: t,
				get isActive() {
					return r() === t.id;
				},
				get store() {
					return e.store;
				},
				get children() {
					return R(ZS, {
						get windowId() {
							return t.id;
						},
						get store() {
							return e.store;
						}
					});
				}
			})
		}), null), t;
	})();
}
//#endregion
//#region src/features/launch/LaunchView.tsx
var tC = /*#__PURE__*/ W("<div class=launch-error style=color:var(--error);margin-top:8px;font-size:12px>"), nC = /*#__PURE__*/ W("<div class=launch-controls><h2>Launch Application</h2><div class=launch-form><label class=launch-label>Application:</label><select class=launch-select></select><button class=launch-btn></button></div><p class=launch-hint>Select a PowerBuilder application (.sra) and click Launch to open the MDI frame environment."), rC = /*#__PURE__*/ W("<div class=launch-view>"), iC = /*#__PURE__*/ W("<option>"), aC = [{
	name: "openpay",
	label: "OpenPay"
}];
function oC(e) {
	let t = e.store.getState(), [n, r] = j("openpay"), i = () => t().windowManager.windows.length > 0, a = () => t().launch.status;
	function o() {
		let t = n();
		e.store.dispatch({
			tag: "launch",
			action: {
				tag: "load-app",
				sraName: t
			}
		});
	}
	return (() => {
		var s = rC();
		return X(s, R(H, {
			get when() {
				return !i();
			},
			get children() {
				var e = nC(), i = e.firstChild.nextSibling, s = i.firstChild.nextSibling, c = s.nextSibling, l = i.nextSibling;
				return s.addEventListener("change", (e) => r(e.currentTarget.value)), X(s, () => aC.map((e) => (() => {
					var t = iC();
					return X(t, () => e.label), N(() => t.value = e.name), t;
				})())), c.$$click = o, X(c, () => a() === "loading" ? "Loading…" : "Launch"), X(e, R(H, {
					get when() {
						return t().launch.error;
					},
					get children() {
						var e = tC();
						return X(e, () => t().launch.error), e;
					}
				}), l), N(() => c.disabled = a() === "loading"), N(() => s.value = n()), e;
			}
		}), null), X(s, R(eC, { get store() {
			return e.store;
		} }), null), s;
	})();
}
G(["click"]);
//#endregion
//#region src/features/navigation/url-sync.ts
function sC(e, t) {
	switch (t.view) {
		case "objectDetail":
			e({
				tag: "objects",
				action: {
					tag: "select",
					name: t.name
				}
			});
			break;
		case "procedureDetail":
			e({
				tag: "objects",
				action: {
					tag: "proc-select",
					objectName: t.name,
					procName: t.proc
				}
			});
			break;
		case "dwDetail":
			e({
				tag: "datawindows",
				action: {
					tag: "select",
					name: t.name
				}
			});
			break;
		case "tableDetail":
			e({
				tag: "tables",
				action: {
					tag: "select",
					name: t.name
				}
			});
			break;
		case "queries":
			e({
				tag: "nav",
				action: {
					tag: "navigate",
					route: t
				}
			}), t.sqlText ? e({
				tag: "queries",
				action: {
					tag: "run-sql",
					sql: t.sqlText
				}
			}) : t.queryName && e({
				tag: "queries",
				action: {
					tag: "restore",
					name: t.queryName,
					params: t.queryParams ?? {}
				}
			});
			break;
		default: e({
			tag: "nav",
			action: {
				tag: "navigate",
				route: t
			}
		});
	}
}
function cC(e) {
	sC(e, on(window.location.pathname, window.location.search));
}
function lC(e) {
	window.addEventListener("popstate", () => {
		sC(e, on(window.location.pathname, window.location.search));
	});
}
//#endregion
//#region src/components/ui/HealthCheck.tsx
var uC = /*#__PURE__*/ W("<div class=health-overlay><div class=health-modal><div class=health-icon></div><h3>Connection lost</h3><p>Unable to reach the backend server.</p><button class=\"filter-pill active\">"), dC = 5e3, fC = "/api/stats";
function pC() {
	let [e, t] = j(!0), [n, r] = j(!1), i;
	async function a() {
		try {
			if ((await fetch(fC, { signal: AbortSignal.timeout(3e3) })).ok) {
				t(!0);
				return;
			}
		} catch {}
		t(!1);
	}
	async function o() {
		r(!0), await a(), r(!1);
	}
	return ae(() => {
		a(), i = setInterval(a, dC);
	}), L(() => {
		i && clearInterval(i);
	}), R(H, {
		get when() {
			return !e();
		},
		get children() {
			var e = uC(), t = e.firstChild.firstChild, r = t.nextSibling.nextSibling.nextSibling;
			return X(t, R(fa, { size: 32 })), r.$$click = o, X(r, () => n() ? "Retrying..." : "Reconnect"), N(() => r.disabled = n()), e;
		}
	});
}
G(["click"]);
//#endregion
//#region src/App.tsx
var mC = $r(ei()), hC = $t(Kr(), Yr, mC);
cC((e) => hC.dispatch(e)), lC((e) => hC.dispatch(e)), hC.dispatch({
	tag: "theme",
	action: { tag: "load" }
}), hC.dispatch({
	tag: "dashboard",
	action: { tag: "load" }
}), hC.dispatch({
	tag: "explore",
	action: { tag: "load" }
});
function gC(e) {
	let t = e.store.getState();
	return R(ko, {
		get store() {
			return e.store;
		},
		get children() {
			return [
				R(H, {
					get when() {
						return t().nav.route.view === "dashboard";
					},
					get children() {
						return R(uc, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "objects";
					},
					get children() {
						return R(_d, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "objectDetail";
					},
					get children() {
						return R(gd, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "procedureDetail";
					},
					get children() {
						return R(Jd, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "proceduresList";
					},
					get children() {
						return R(of, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "datawindows";
					},
					get children() {
						return R(If, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "dwDetail";
					},
					get children() {
						return R(Ff, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "tables" || t().nav.route.view === "tableDetail";
					},
					get children() {
						return R(gp, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "diagrams";
					},
					get children() {
						return R(ub, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "queries";
					},
					get children() {
						return R(kb, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "search";
					},
					get children() {
						return R(Hb, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "explore";
					},
					get children() {
						return R(Yb, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "errors";
					},
					get children() {
						return R(vx, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "libraryDetail";
					},
					get children() {
						return R(Ex, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "deadCode";
					},
					get children() {
						return R(Rx, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "taintExplorer";
					},
					get children() {
						return R(qx, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "taintPathView";
					},
					get children() {
						return R(bS, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "sliceView";
					},
					get children() {
						return R(wS, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "formalReports";
					},
					get children() {
						return R(ES, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "cfgDiagram";
					},
					get children() {
						return R(DS, { get store() {
							return e.store;
						} });
					}
				}),
				R(H, {
					get when() {
						return t().nav.route.view === "launch";
					},
					get children() {
						return R(oC, { get store() {
							return e.store;
						} });
					}
				})
			];
		}
	});
}
function _C() {
	return [
		R(gC, { store: hC }),
		R(Xo, { store: hC }),
		R(ns, { store: hC }),
		R(pC, {})
	];
}
var vC = document.getElementById("app");
vC && it(() => R(_C, {}), vC);
//#endregion
