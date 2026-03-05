/*
 * Infoblox Universal DDI - PVE SDN IPAM & DNS InputPanels
 *
 * Registers the 'infobloxuddi' plugin type in PVE's schema objects
 * and defines InputPanel classes for the web UI Add/Edit dialogs.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

// ── Schema Registration ────────────────────────────────────────────────────

PVE.Utils.sdnipamSchema.infobloxuddi = {
    name: 'Infoblox UDDI',
    ipanel: 'InfobloxuddiInputPanel',
    faIcon: 'th',
};

PVE.Utils.sdndnsSchema.infobloxuddi = {
    name: 'Infoblox UDDI',
    ipanel: 'InfobloxuddiInputPanel',
    faIcon: 'th',
};

// ── IPAM InputPanel ────────────────────────────────────────────────────────

Ext.define('PVE.sdn.ipams.InfobloxuddiInputPanel', {
    extend: 'PVE.panel.SDNIpamBase',

    onGetValues: function(values) {
	var me = this;
	if (me.isCreate) {
	    values.type = me.type;
	} else {
	    delete values.ipam;
	}
	return values;
    },

    initComponent: function() {
	var me = this;

	me.column1 = [
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'ipam',
		maxLength: 10,
		value: me.zone || '',
		fieldLabel: 'ID',
		allowBlank: false,
	    },
	    {
		xtype: 'textfield',
		name: 'token',
		fieldLabel: gettext('Token'),
		inputType: 'password',
		allowBlank: false,
	    },
	];

	me.column2 = [
	    {
		xtype: 'textfield',
		name: 'url',
		fieldLabel: gettext('URL'),
		emptyText: 'https://csp.eu.infoblox.com',
		allowBlank: false,
	    },
	    {
		xtype: 'textfield',
		name: 'ip_space',
		fieldLabel: gettext('IP Space'),
		allowBlank: false,
	    },
	];

	me.columnB = [
	    {
		xtype: 'pmxFingerprintField',
		name: 'fingerprint',
		value: me.isCreate ? null : undefined,
		deleteEmpty: !me.isCreate,
	    },
	];

	me.callParent();
    },
});

// ── DNS InputPanel ─────────────────────────────────────────────────────────

Ext.define('PVE.sdn.dns.InfobloxuddiInputPanel', {
    extend: 'PVE.panel.SDNDnsBase',

    onGetValues: function(values) {
	var me = this;
	if (me.isCreate) {
	    values.type = me.type;
	} else {
	    delete values.dns;
	}
	return values;
    },

    initComponent: function() {
	var me = this;

	me.column1 = [
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'dns',
		maxLength: 10,
		value: me.zone || '',
		fieldLabel: 'ID',
		allowBlank: false,
	    },
	    {
		xtype: 'textfield',
		name: 'token',
		fieldLabel: gettext('Token'),
		inputType: 'password',
		allowBlank: false,
	    },
	];

	me.column2 = [
	    {
		xtype: 'textfield',
		name: 'url',
		fieldLabel: gettext('URL'),
		emptyText: 'https://csp.eu.infoblox.com',
		allowBlank: false,
	    },
	    {
		xtype: 'textfield',
		name: 'dns_view',
		fieldLabel: gettext('DNS View'),
		emptyText: 'default',
		allowBlank: true,
	    },
	    {
		xtype: 'proxmoxintegerfield',
		name: 'ttl',
		fieldLabel: 'TTL',
		allowBlank: true,
		emptyText: '3600',
	    },
	];

	me.columnB = [
	    {
		xtype: 'pmxFingerprintField',
		name: 'fingerprint',
		value: me.isCreate ? null : undefined,
		deleteEmpty: !me.isCreate,
	    },
	];

	me.callParent();
    },
});
