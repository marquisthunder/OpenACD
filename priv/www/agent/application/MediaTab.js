dojo.provide("agentUI.MediaTab");
dojo.require("dijit._Widget");
dojo.require("dijit._Templated");
dojo.require("dijit.form.Button");

dojo.declare("agentUI.MediaTab", [dijit._Widget, dijit._Templated], {
	templatePath: dojo.moduleUrl("agentUI","MediaTab.html"),
	widgetsInTemplate: true,
	//templateString: "",

	constructor: function(args, srcNodeRef){
		console.log('media tab', args, srcNodeRef);
		dojo.safeMixin(this, args);
		this.title = args.stateData.type + ' - ' + args.channel;
		this._agentSub = dojo.subscribe("OpenACD/AgentChannel", this, this._handleAgentChannelPublish);
		this._agentCommandSubs = {};
		this._agentCommandSubs.mediaload = dojo.subscribe("OpenACD/AgentChannel/" + this.channel + "/mediaload", this, function(args){
			console.log("loading media", args);
			this.mediaPane.attr('href', "tabs/" + args.media + "_media.html");
		});
		/*switch(args.state){
			case 'ringing':
				this.answerButton.domNode.style.display = '';
				break;
		}*/
	},


	postCreate: function(){
		dojo.query('label.narrow', this.domNode).forEach(function(node){
			var text = dojo.i18n.getLocalization("agentUI", "labels")[node.innerHTML];
			node.innerHTML = text;
		});
		this.agentStateNode.innerHTML = dojo.i18n.getLocalization("agentUI", "labels")[this.state.toUpperCase()];

		this.agentBrandNode.innerHTML = this.stateData.brandname;
		this.calleridNode.innerHTML = this.stateData.callerid;
		this.callTypeNode.innerHTML = this.stateData.type;

		dojo.connect(this.answerButton, 'onClick', this, function(){
			window.agentConnection.channels[this.channel].setState('oncall');
		});
		dojo.connect(this.hangupButton, 'onClick', this, function(){
			window.agentConnection.channels[this.channel].setState('wrapup');
		});
		dojo.connect(this.endWrapupButton, 'onClick', this, function(){
			window.agentConnection.channels[this.channel].endWrapup();
		});
	},

	_handleAgentChannelPublish: function(channelId, args){
		if(channelId != this.channel){
			return false;
		}
		console.log('event', this, arguments);
		switch(args){

			case 'oncall':
				this.answerButton.domNode.style.display = 'none';
				if(arguments[2].mediapath == 'inband'){
					this.hangupButton.domNode.style.display = 'inline';
				}
				break;

			case 'wrapup':
				this.answerButton.domNode.style.display = 'none';
				this.hangupButton.domNode.style.display = 'none';
				this.endWrapupButton.domNode.style.display = 'inline';
				break;
		}
	}/*,
	doAnswer: function(opts){
		if(opts.mode == 'href'){
			this.mediaPane.attr('href', opts.content);
		} else {
			this.mediaPane.attr('content', opts.content);
		}
	}*/
});
