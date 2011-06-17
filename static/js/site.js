var Cpip = {};
Cpip.tabCtrl = Class.create({
    initialize: function(classname) {
        this.tabs = $A(document.getElementsByClassName(classname));
        this.tabs.collect( this.observeEle.bind(this) );
        this.changeEle(this.tabs[0]);
    },
    observeEle: function(v) {
        Event.observe( v, 'click', function(event){ this.changeEle(Event.element(event)) }.bindAsEventListener(this) );
    },
    changeEle: function(ele) {
         this.tabs.collect( function(v){ this.hideEle(v) }.bind(this) );
         this.showEle(ele);
    },
    hideEle: function(ele) {
        ele.removeClassName('mtab_on');
        ele.addClassName('mtab_off');
        $(ele.id + "_content").hide();
    },
    showEle: function(ele) {
        ele.removeClassName('mtab_off');
        ele.addClassName('mtab_on');
        $(ele.id + "_content").show();
    }
});

Cpip.tabPreview = Class.create({
    initialize: function(button,textarea,preview) {
        this.button = $(button);
        this.textarea = $(textarea);
        this.preview = $(preview);
        Event.observe( this.button, 'click', function() {
            var height = this.textarea.getHeight();
            this.preview.style.height = height+'px';
            new Ajax.Updater(
                this.preview,
                '/account/preview',
                {
                    parameters: { body: $F(this.textarea), postkey: $F('postkey') }
                }
            );
        }.bindAsEventListener(this) );
    }
});


Cpip.updateAclCustomList = Class.create({
    initialize: function(mode,new_openid) {
        this.mode = mode;
        this.new_openid = new_openid;
        new Ajax.Request( '/account/network', {
            parameters: { postkey: $F('postkey') },
            onSuccess: this.successGet.bindAsEventListener(this),
            onFailure: this.failedGet.bindAsEventListener(this)
        });
    },
    failedGet: function() {
        $('acl_view_custom_wrap').innterHTML = '<p>failed to get list</p>';
        $('acl_modify_custom_wrap').innterHTML = '<p>failed to get list</p>';
    },
    successGet: function(trans) {
        var network = trans.responseText.evalJSON();
        this.generateList(network.network,'view');
        this.generateList(network.network,'modify');
    },
    generateList: function(network,key) {
        var checked = this.checkedOpenid(key);
        var input = '<ul>';
        $A(network).collect(function(v) {
            input += '<li><label><input type="checkbox" name="acl_custom_'+
                key +
                '_openid" value="' +
                v.escapeHTML() +
                '" ';
             if ( $A(checked).include(v) ||
                  ( this.mode == key && v == this.new_openid )
                ) input += 'checked="checked" ';
             input += '/> ' +
                v.escapeHTML() +
                '</label></li>';
        }.bind(this) );
        input += '</ul>';
        $('acl_'+key+'_custom_wrap').innerHTML = input;
        if ( this.mode == key ) {
            var find = $A($('create')['acl_custom_'+key+'_openid']).find(function(v) {
                if ( $F(v) == this.new_openid ) {
                    $('acl_'+key+'_custom_wrap').scrollTop = v.parentNode.parentNode.offsetTop;
                    new Effect.Highlight(v.parentNode.parentNode,{});
                }
            }.bind(this) );
        }
    },
    checkedOpenid: function(key){
        this.key = key;
        var find = $('create').getInputs('checkbox','acl_custom_'+key+'_openid').findAll(function(v) {
            return v.checked;
        });
        return find.collect( function(c) {
            return $F(c);
        });
    }
});

Cpip.aclCustom = Class.create({
    initialize: function(mode){
        this.mode = mode;
        Event.observe($('acl_'+mode+'_custom_add_text'),
            'keydown',this.keyDownCustomAddText.bindAsEventListener(this));

        var input = $('acl_'+mode+'_custom_add_text')
        if (input.addEventListener) {
            input.addEventListener('keydown', this.keyDownCustomAddText.bindAsEventListener(this), true );
            input.addEventListener('keyup', this.keyUpCustomAddText.bindAsEventListener(this), true );
            input.addEventListener('keypress', this.keyPressCustomAddText.bindAsEventListener(this), true );
        } else {
           input.attachEvent('onkeydown', this.keyDownCustomAddText.bindAsEventListener(this) );
           input.attachEvent('onkeyup', this.keyUpCustomAddText.bindAsEventListener(this) );
           input.attachEvent('onkeypress', this.keyPressCustomAddText.bindAsEventListener(this) );
        }

        Event.observe($('acl_'+mode+'_custom_add_button'),
            'click', function(event){ this.addNewURL($('acl_'+this.mode+'_custom_add_text')) }.bindAsEventListener(this));
        $('create').getInputs('radio','acl_'+this.mode+'_mode').collect(function(v) {
            Event.observe(v,
                'click', this.changeMode.bindAsEventListener(this));
        }.bind(this));
        this.changeMode();
    },
    changeMode: function() {
        var r = $A($('create')['acl_'+this.mode+'_mode']).find(function(v) {
            return v.checked;
        });
        if ( r.value == 3 ) {
            this.enableCustom();
        } else {
            this.disableCustom();
        }
    },
    enableCustom: function() {
        if ( $('create')['acl_custom_'+this.mode+'_openid'] != undefined ) {
            $('create').getInputs('checkbox','acl_custom_'+this.mode+'_openid').collect(function(v) {
                $(v).enable();
            });
        }
        $('acl_'+this.mode+'_custom_add_text').enable();
        $('acl_'+this.mode+'_custom_add_button').enable();
        $('acl_'+this.mode+'_custom_wrap').removeClassName('acl_custom_select_wrap_off');
        $('acl_'+this.mode+'_custom_wrap').addClassName('acl_custom_select_wrap_on');
    },
    disableCustom: function() {
        $('create').getInputs('checkbox','acl_custom_'+this.mode+'_openid').collect(function(v) {
            $(v).disable();
        });
        $('acl_'+this.mode+'_custom_add_text').disable();
        $('acl_'+this.mode+'_custom_add_button').disable();
        $('acl_'+this.mode+'_custom_wrap').removeClassName('acl_custom_select_wrap_on');
        $('acl_'+this.mode+'_custom_wrap').addClassName('acl_custom_select_wrap_off');
    },
    keyDownCustomAddText: function(event){
        this.customkeycode = event.keyCode;
    },
    keyUpCustomAddText: function(event){
        this.customkeycode = 0;
        setTimeout( function(){ this.grepList(); }.bind(this), 10 );
    },
    keyPressCustomAddText: function(event){
        if (this.customkeycode == Event.KEY_RETURN ) {
            var ele = Event.element(event);
            Event.stop(event);
            setTimeout( function(){ this.addNewURL(ele); }.bind(this), 10 );
            return;
        }
    },
    grepList: function() {
        var regex = new RegExp( $F('acl_'+this.mode+'_custom_add_text').replace(/(?=\W)/, "\\"), 'i' );
        $('create').getInputs('checkbox','acl_custom_'+this.mode+'_openid').collect(function(v) {
            var text = v.parentNode.innerHTML.stripTags();
            if ( text.match(regex) ) {
                $(v.parentNode.parentNode).show();
            } else {
                $(v.parentNode.parentNode).hide();
            }
        });
    },
    addNewURL: function(ele) {
        this.ele = ele;
        if ( this.ele.disabled == true ) return false;
        var url = $F(ele);
        if ( url.length < 4 ) {
            return false;
        }
        this.ele.disable();
        var request = new Ajax.Request( '/account/add_network', {
            parameters: { openid_url: url, postkey: $F('postkey') },
            onSuccess: this.successAddNewURL.bindAsEventListener(this),
            onFailure: this.failedAddNewURL.bindAsEventListener(this)
        });
        return false;
    },
    successAddNewURL: function(trans){
        var json = trans.responseText.evalJSON();
        var update_acl = new Cpip.updateAclCustomList(this.mode,json.openid_url);
        this.ele.clear();
        this.ele.enable();
        this.ele.focus();
    },
    failedAddNewURL: function(){
        this.ele.enable();
        this.ele.focus();
        new Effect.Highlight(this.ele,{
            startcolor: "#ffcccc", endcolor: "#ffffff", restorecolor: "#ffffff" });
    }
});

Cpip.articleHistoryDiff = Class.create({
    initialize: function(id) {
        this.modify_ele = $('article_history_'+id);
        this.diff_ele = $('article_history_diff_'+id);
        Event.observe(this.modify_ele,
            'click', this.onclick.bindAsEventListener(this));
    },
    onclick: function() {
        this.diff_ele.toggle();
    }
});
