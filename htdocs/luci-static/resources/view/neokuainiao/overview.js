'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require poll';

var CRED_PATH  = '/etc/neokuainiao/cred.env';
var STATE_PATH = '/var/run/neokuainiao/status.json';
var LOGIN_PW   = '/var/run/neokuainiao/login.pw';
var KPN        = '/usr/libexec/neokuainiao/kpn.sh';
var INITD      = '/etc/init.d/neokuainiao';

var STATE_TEXT = {
	'running':        [ '正常提速中', 'cbi-button-positive' ],
	'up':             [ '提速已下发', 'cbi-button-positive' ],
	'ok':             [ '线路可提速', 'cbi-button-positive' ],
	'down':           [ '已恢复带宽', '' ],
	'disabled':       [ '服务已关闭', '' ],
	'no_cred':        [ '未导入凭证', 'cbi-button-negative' ],
	'no_upgrade':     [ '线路不可提速', 'cbi-button-negative' ],
	'up_fail':        [ '提速失败', 'cbi-button-negative' ],
	'keepalive_fail': [ '心跳失败（可能已掉速）', 'cbi-button-negative' ],
	'unknown':        [ '状态未知', '' ]
};

function mbps(kbps) {
	var v = parseInt(kbps, 10) || 0;
	if (v <= 0) return '—';
	return (v / 1024).toFixed(0) + ' Mbps';
}

function fmtTime(ts) {
	var t = parseInt(ts, 10) || 0;
	if (t <= 0) return '—';
	var d = new Date(t * 1000);
	var p = function (n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
		p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function readState() {
	return fs.read(STATE_PATH).then(function (s) {
		try { return JSON.parse(s); } catch (e) { return null; }
	}).catch(function () { return null; });
}

function runKpn(cmd) {
	return fs.exec(KPN, [ cmd ]).then(function (res) {
		var out = (res.stdout || '').trim();
		if (res.code !== 0 && !out)
			out = (res.stderr || '').trim() || ('返回码 ' + res.code);
		// rc=2 = 被服务端限流（errno=711），稍后会自动恢复，不算失败
		return { ok: res.code === 0 || res.code === 2, text: out };
	}).catch(function (e) {
		return { ok: false, text: e.message || String(e) };
	});
}

/* 解析脚本输出的 KEY=VALUE（逐行，值为空也算一个键） */
function parseKV(txt) {
	var o = {};
	(txt || '').split('\n').forEach(function (line) {
		var i = line.indexOf('=');
		if (i > 0) o[line.substring(0, i)] = line.substring(i + 1);
	});
	return o;
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('neokuainiao'),
			fs.read(CRED_PATH).catch(function () { return ''; })
		]);
	},

	render: function (data) {
		var credText = data[1] || '';
		var self = this;
		var statusBody = E('div', {}, E('em', {}, _('读取中…')));
		var actionMsg = E('p', { 'class': 'cbi-section-descr' }, '');
		var credArea;

		/* ---------------- 状态面板 ---------------- */
		function paint(st) {
			if (!st) {
				statusBody.innerHTML = '';
				statusBody.appendChild(E('em', {}, _('暂无状态数据，服务可能未运行')));
				return;
			}
			var t = STATE_TEXT[st.state] || STATE_TEXT['unknown'];
			var rows = [
				[ _('当前状态'), E('span', { 'class': 'label ' + t[1] }, t[0]) ],
				[ _('下行带宽'), mbps(st.cur_down) + '  /  上限 ' + mbps(st.max_down) ],
				[ _('上行带宽'), mbps(st.up_cur) + (st.up_supported == 1 ? _('（支持提速）') : _('（不支持提速）')) ],
				[ _('线路'), (st.province || '—') + ' / ' + (st.sp || '—') ],
				[ _('拨号账号'), st.dial || '—' ],
				[ _('最近提速'), fmtTime(st.last_up) ],
				[ _('状态更新'), fmtTime(st.ts) ]
			];
			if (st.msg) rows.push([ _('附加信息'), st.msg ]);
			if (st.errno && st.errno != '0') rows.push([ _('errno'), st.errno ]);

			statusBody.innerHTML = '';
			statusBody.appendChild(E('table', { 'class': 'table' },
				rows.map(function (r) {
					// 注意：LuCI 的 E(tag, attrs, child) 只接受**一个** child 参数，
					// 多个子节点必须包成数组，否则第二个及以后的参数会被静默丢弃
					// （曾因此整个值列都不渲染，页面看着像"没有状态"）。
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'width': '30%' }, r[0]),
						E('td', { 'class': 'td' }, r[1])
					]);
				})));
		}

		function refresh() {
			return readState().then(function (st) { paint(st); });
		}

		function doAction(cmd, label) {
			actionMsg.textContent = _('正在执行：%s …').format(label);
			return runKpn(cmd).then(function (r) {
				actionMsg.textContent = label + '：' + (r.ok ? _('成功') : _('失败'));
				ui.addNotification(null,
					E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, r.text || (r.ok ? _('完成') : _('无输出'))),
					r.ok ? 'info' : 'warning');
				return refresh();
			});
		}

		var btnRow = E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left;margin:0 0 1em' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, function () { return doAction('run-once', _('立即提速并心跳')); })
			}, _('立即提速')),
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function () { return doAction('down', _('恢复带宽')); })
			}, _('恢复带宽')),
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function () { return doAction('renew', _('续期会话')); })
			}, _('续期会话')),
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function () {
					actionMsg.textContent = _('已刷新');
					return refresh();
				})
			}, _('刷新状态'))
		]);

		var statusPanel = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			statusBody,
			E('div', { 'style': 'margin-top:1em' }, btnRow),
			actionMsg
		]);

		/* ---------------- 凭证导入 ---------------- */
		credArea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%;min-height:9em;font-family:monospace;font-size:12px',
			'placeholder': "KP_USERID='...'\nKP_LOGINKEY='...'\nKP_SESSION='...'\nKP_PEERID='...'\nKP_DEVICESIGN='...'"
		});
		credArea.value = credText;

		function saveCred() {
			var txt = (credArea.value || '').trim();
			if (!txt) {
				ui.addNotification(null, E('p', {}, _('内容为空，未保存')), 'warning');
				return Promise.resolve();
			}
			if (txt.indexOf('KP_USERID') < 0 || txt.indexOf('KP_PEERID') < 0) {
				ui.addNotification(null, E('p', {}, _('内容缺少 KP_USERID 或 KP_PEERID，请粘贴完整的 cred.env 内容')), 'error');
				return Promise.resolve();
			}
			return fs.write(CRED_PATH, txt + '\n', 384).then(function () {
				ui.addNotification(null, E('p', {}, _('凭证已保存（权限 600）')), 'info');
				return runKpn('renew').then(function (r) {
					ui.addNotification(null,
						E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, r.text || ''),
						r.ok ? 'info' : 'warning');
					return refresh();
				});
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, _('保存失败：') + (e.message || e)), 'error');
			});
		}

	var credPanel = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('凭证导入（备用方式）')),
		E('p', { 'class': 'cbi-section-descr' }, [
			_('不想在路由器上输密码时，可以在电脑上（与路由器同一出口 IP）执行一次登录，把生成的文件内容粘贴到这里：'),
			E('br'),
			E('code', {}, './kp-login.sh auto'),
			E('br'),
			E('code', {}, 'cat /tmp/kp-state.env'),
			E('br'),
			_('（kp-login.sh 需与路由器处于同一出口 IP；登录成功后把上面命令的输出整段粘进下方文本框）'),
			E('br'),
			_('提示：loginKey 有效期长，日常靠它静默续期；peerID / devicesign 必须与登录时一致，请勿手改。')
		]),
			credArea,
			E('div', { 'style': 'margin-top:.8em' },
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, saveCred)
				}, _('保存凭证并续期')))
		]);

		/* ---------------- 账号密码 + 图形验证码登录 ---------------- */
		var lgnUser = E('input', {
			'class': 'cbi-input-text', 'type': 'text', 'autocomplete': 'off',
			'placeholder': _('迅雷账号 / 手机号'), 'style': 'width:14em'
		});
		var lgnPass = E('input', {
			'class': 'cbi-input-password', 'type': 'password', 'autocomplete': 'off',
			'placeholder': _('迅雷密码'), 'style': 'width:14em'
		});
		var lgnCap = E('input', {
			'class': 'cbi-input-text', 'type': 'text', 'autocomplete': 'off',
			'maxlength': '6', 'placeholder': _('验证码'),
			'style': 'width:8em;font-family:monospace;letter-spacing:2px;text-transform:uppercase'
		});
		var lgnImg = E('img', {
			'alt': _('验证码'),
			'style': 'display:none;max-width:280px;background:#fff;border:1px solid #bbb;padding:2px'
		});
		var lgnMsg = E('div', { 'class': 'cbi-section-descr', 'style': 'min-height:1.4em' }, '');

		var capRow = E('div', { 'style': 'display:none;margin-top:.9em' }, [
			lgnImg,
			E('div', { 'style': 'margin-top:.6em' }, [
				lgnCap, ' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () { return doSubmitCode(); })
				}, _('提交验证码')), ' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () { return doRefreshCode(); })
				}, _('换一张'))
			])
		]);

		function showCaptcha(kv) {
			if (!kv.IMAGE_B64) {
				lgnMsg.textContent = _('未取得验证码图片');
				return;
			}
			lgnImg.src = 'data:image/jpeg;base64,' + kv.IMAGE_B64;
			lgnImg.style.display = '';
			capRow.style.display = '';
			lgnMsg.textContent = _('验证码已就绪（%s 字节），请输入图片中的字符').format(kv.IMAGE_BYTES || '?');
			lgnCap.value = '';
			try { lgnCap.focus(); } catch (e) {}
		}

		function hideCaptcha() {
			capRow.style.display = 'none';
			lgnImg.style.display = 'none';
			lgnImg.removeAttribute('src');
		}

		function handleLoginKV(kv) {
			if (kv.STAGE === 'captcha') { showCaptcha(kv); return Promise.resolve(); }

			if (kv.STAGE === 'ok') {
				hideCaptcha();
				lgnPass.value = '';
				lgnMsg.textContent = _('登录成功 userID=%s，凭证已写入').format(kv.USERID || '?');
				ui.addNotification(null,
					E('p', {}, _('登录成功，凭证已保存。正在开启服务并立即提速…')), 'info');
				return uci.set('neokuainiao', 'main', 'enabled', '1')
					.then(function () { return uci.save('neokuainiao'); })
					.then(function () { return uci.apply(); })
					.catch(function () {})
					.then(function () { return fs.exec(INITD, [ 'restart' ]).catch(function () {}); })
					.then(function () { return fs.exec(KPN, [ 'run-once' ]).catch(function () {}); })
					.then(function () { return refresh(); });
			}

			lgnMsg.textContent = (kv.MSG || _('登录失败')) +
				(kv.ERRORCODE ? '（errorCode=' + kv.ERRORCODE + '）' : '');
			if (kv.MSG)
				ui.addNotification(null, E('p', {}, kv.MSG), 'warning');
			return Promise.resolve();
		}

		function doPrepareLogin() {
			var u = (lgnUser.value || '').trim(), p = lgnPass.value || '';
			if (!u) { ui.addNotification(null, E('p', {}, _('请填写迅雷账号')), 'warning'); return Promise.resolve(); }
			if (!p) { ui.addNotification(null, E('p', {}, _('请填写迅雷密码')), 'warning'); return Promise.resolve(); }
			lgnMsg.textContent = _('正在登录并获取验证码…');
			hideCaptcha();
			return fs.write(LOGIN_PW, p, 384).then(function () {
				return fs.exec(KPN, [ 'login-prepare', u ]);
			}).then(function (res) {
				var kv = parseKV(res.stdout);
				if (!kv.STAGE) {
					lgnMsg.textContent = (res.stderr || _('脚本无输出')).trim();
					return;
				}
				if (kv.STAGE === 'captcha') lgnPass.value = '';
				return handleLoginKV(kv);
			}).catch(function (e) {
				lgnMsg.textContent = _('请求失败：') + (e.message || e);
			});
		}

		function doSubmitCode() {
			var c = (lgnCap.value || '').replace(/\s+/g, '');
			if (!c) { ui.addNotification(null, E('p', {}, _('请填写验证码')), 'warning'); return Promise.resolve(); }
			lgnMsg.textContent = _('正在校验验证码…');
			return fs.exec(KPN, [ 'login-submit', c ]).then(function (res) {
				var kv = parseKV(res.stdout);
				if (!kv.STAGE) {
					lgnMsg.textContent = (res.stderr || _('脚本无输出')).trim();
					return;
				}
				return handleLoginKV(kv);
			}).catch(function (e) {
				lgnMsg.textContent = _('请求失败：') + (e.message || e);
			});
		}

		function doRefreshCode() {
			lgnMsg.textContent = _('正在换一张…');
			return fs.exec(KPN, [ 'login-refresh' ]).then(function (res) {
				var kv = parseKV(res.stdout);
				if (kv.STAGE === 'captcha') return handleLoginKV(kv);
				lgnMsg.textContent = (kv.MSG || res.stderr || _('换图失败'));
			}).catch(function (e) {
				lgnMsg.textContent = _('请求失败：') + (e.message || e);
			});
		}

		lgnCap.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); doSubmitCode(); }
		});
		lgnPass.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); doPrepareLogin(); }
		});

		var loginPanel = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('账号密码登录（可直接在这里输验证码）')),
			E('p', { 'class': 'cbi-section-descr' }, [
				_('在这台路由器上完成登录：先提交账号密码，服务端要求图形验证码时下方会显示图片，输入 4 个字符即可。'),
				E('br'),
				_('登录成功后只保存 loginKey / userID / peerID / devicesign，日常靠 loginKey 静默续期，不再需要密码和验证码。')
			]),
			E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.6em;align-items:center' }, [
				lgnUser, lgnPass,
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function () { return doPrepareLogin(); })
				}, _('获取验证码'))
			]),
			capRow,
			lgnMsg,
			E('p', { 'class': 'cbi-section-descr', 'style': 'margin-top:.6em;opacity:.8' }, [
				_('安全说明：密码只经内存（tmpfs）传给本机脚本，登录成功、取消或 10 分钟超时后立即删除，不写入 flash、不写入配置备份。'),
				E('br'),
				_('如果密码含特殊字符仍报 errorCode=3，请确认输入法没有把 ! ( * 打成全角符号。')
			])
		]);

		/* ---------------- 设置表单 ---------------- */
	var m = new form.Map('neokuainiao', _('迅雷快鸟提速'),
		_('用上面的账号密码登录（或导入凭证）后开启服务，路由器会常驻保活：查带宽 → 按需提速 → 心跳保活，掉速自动重试。'));

		var s = m.section(form.NamedSection, 'main', 'neokuainiao', _('基本设置'));
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('启用'),
			_('开启后由 procd 托管常驻，开机自启。'));
		o.rmempty = false;

	o = s.option(form.Value, 'interval', _('轮询间隔（秒）'),
		_('两轮处理（查带宽 → 心跳保活）之间的等待时间。服务端把提速/心跳视为同类「点击」请求、最小间隔约 120 秒：提完速的当轮会自动跳过心跳，点击窗口内也只保活不点击；失败（掉速/瞬时错误）按 300 秒重试。建议 300~900。'));
		o.datatype = 'range(120,3600)';
		o.placeholder = '300';
		o.rmempty = false;

		o = s.option(form.Value, 'iface', _('出口接口（可选）'),
			_('多 WAN / 旁路由场景填写 WAN 接口名（如 pppoe-wan），确保请求从宽带出口发出；只有 curl 可用时才生效。'));
		o.placeholder = 'pppoe-wan';
		o.rmempty = true;

		var map = m;
		map.handleSaveApply = ui.createHandlerFn(this, function () {
			return map.save().then(function () {
				return fs.exec(INITD, [ 'restart' ]).catch(function () {});
			}).then(function () {
				ui.addNotification(null, E('p', {}, _('配置已保存，服务已重启')), 'info');
				return refresh();
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, _('保存失败：') + (e.message || e)), 'error');
			});
		});

		/* ---------------- 轮询 ---------------- */
		poll.add(function () { return refresh(); }, 10);
		poll.start();

		return map.render().then(function (node) {
			return E('div', {}, [ statusPanel, loginPanel, credPanel, node ]);
		}).then(function (node) {
			return refresh().then(function () { return node; });
		});
	}
});
