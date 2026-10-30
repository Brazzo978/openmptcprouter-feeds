'use strict';
'require view';
'require omr.profiles as profiles';

return view.extend({
	render: function() {
		var root = E('div', {}, [
			E('h2', {}, _('Connection profiles')),
			profiles.create({ full: true })
		]);
		return root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
