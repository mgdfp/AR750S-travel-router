'use strict';
'require baseclass';
'require fs';
'require rpc';

// "Uplink" card at the top of Status → Overview: the travelmate Wi-Fi uplink
// at a glance. The overview page re-runs load() every few seconds; the
// internet check behind it is only repeated every CHECK_INTERVAL.

var TRM_IFACE = 'trm_wwan';
var TRM_STATUS = '/var/run/travelmate/travelmate.runtime.json';
var CHECK_INTERVAL = 30000;

var callIfaceStatus = rpc.declare({
	object: 'network.interface',
	method: 'status',
	params: [ 'interface' ]
});

var callWifiInfo = rpc.declare({
	object: 'iwinfo',
	method: 'info',
	params: [ 'device' ]
});

var lastCheck = 0, lastResult = null;

function checkInternet() {
	if (Date.now() - lastCheck < CHECK_INTERVAL)
		return Promise.resolve(lastResult);

	lastCheck = Date.now();
	return L.resolveDefault(fs.exec_direct('/usr/libexec/uplink-check'), null).then(function(res) {
		lastResult = res ? res.trim() : null;
		return lastResult;
	});
}

function dot(color, text) {
	return E('span', { 'style': 'font-weight:bold' }, [
		E('span', { 'style': 'color:%s'.format(color) }, [ '● ' ]), text
	]);
}

function state(trm, iface, check) {
	if (!trm)
		return dot('#d9534f', _('Travelmate not running'));
	if (!iface.up)
		return dot('#d9534f', _('Not connected to any uplink'));
	if (check == null)
		return dot('#888', _('Checking…'));
	if (check == 'ok')
		return dot('#2e9d5b', _('Online'));
	if (check == 'offline')
		return dot('#d9534f', _('Connected, but no internet'));

	// The URL comes from the portal's redirect; never link anything but http(s).
	var url = check.replace(/^portal\s*/, '');
	if (!/^https?:\/\//i.test(url))
		url = null;

	return E('span', {}, [
		dot('#e08a00', _('Captive portal, log in to get online')), ' ',
		url ? E('a', { 'href': url, 'target': '_blank', 'rel': 'noreferrer' }, [ _('Open login page') ]) : ''
	]);
}

return baseclass.extend({
	title: _('Uplink'),

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read_direct(TRM_STATUS, 'json'), null),
			L.resolveDefault(callIfaceStatus(TRM_IFACE), {}),
			checkInternet()
		]).then(function(data) {
			var dev = data[1].up ? data[1].l3_device : null;
			return L.resolveDefault(dev ? callWifiInfo(dev) : Promise.resolve({}), {}).then(function(wifi) {
				return data.concat([ wifi ]);
			});
		});
	},

	render: function(data) {
		var trm = data[0] && data[0].data, iface = data[1], check = data[2], wifi = data[3];
		var addr = (iface['ipv4-address'] || [])[0];
		var quality = wifi.quality_max ? Math.round(wifi.quality * 100 / wifi.quality_max) : null;

		var fields = [
			_('Status'), state(trm, iface, check),
			_('Network'), iface.up ? wifi.ssid : null,
			_('Signal'), wifi.signal ? '%d dBm (%d%%), %s, channel %d'.format(
				wifi.signal, quality, wifi.frequency > 4000 ? '5 GHz' : '2.4 GHz', wifi.channel) : null,
			_('Address'), addr ? '%s/%d'.format(addr.address, addr.mask) : null,
			_('Travelmate'), trm ? trm.travelmate_status : null
		];

		var table = E('table', { 'class': 'table' });
		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
				E('td', { 'class': 'td left' }, [ (fields[i + 1] != null) ? fields[i + 1] : '-' ])
			]));
		}

		return E('div', {}, [
			table,
			E('p', {}, [ E('a', { 'href': L.url('admin/services/travelmate/stations') }, [ _('Manage uplink networks →') ]) ])
		]);
	}
});
