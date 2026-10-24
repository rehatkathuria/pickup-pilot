import Foundation

/// Selectors verified against Apple's public rs-checkout 5.18.11 source on 2026-10-16.
/// This is an intentionally conservative page adapter; new page shapes pause for inspection.
enum AppleCheckoutScripts {
    static let bootstrap = #"""
    (() => {
      if (location.protocol !== 'https:' || !/(^|\.)apple\.com$/i.test(location.hostname)) return;
      const submissionDisabled=window.__pickupPilotReviewOnly===true;
      // A new document at the same checkout URL cannot inherit a previous review approval.
      const documentID=(()=>{try{return globalThis.crypto.randomUUID();}catch(_){return null;}})();
      const models = [];
      let responseSequence=0;
      let checkoutBlocked=false;
      let blockingStatus=null, blockingSource=null;
      let notificationPending=false, pendingModels=0, pendingNetwork=0;
      const changed=()=>{
        if(notificationPending)return;
        notificationPending=true;
        setTimeout(()=>{
          notificationPending=false;
          // A constant carries no page content, profile fields, URL or session data.
          try{window.webkit?.messageHandlers?.pickupPilotChanged?.postMessage(1);}catch(_){}
        },0);
      };
      new MutationObserver(changed).observe(document,{childList:true,subtree:true,characterData:true,attributes:true,
        attributeFilter:['disabled','aria-disabled','aria-invalid','aria-busy','hidden','class','style','checked','selected']});
      document.addEventListener('DOMContentLoaded',changed,{once:true});
      document.addEventListener('input',changed,true);
      document.addEventListener('change',changed,true);
      const responseRoute=target=>{
        const path=target.pathname.toLowerCase();
        if(/^\/(?:[a-z]{2}\/)?shop\/(?:go\/)?404\/?$/.test(path))return 'pageNotFound';
        if(/^\/(?:[a-z]{2}\/)?shop\/(?:go\/)?(?:403|429|541|error)(?:\/|$)/.test(path))return 'securityError';
        if(/\/shop\/bag\/?$/.test(path))return 'bag';
        if(/\/shop\/signin\/?$/.test(path))return 'signIn';
        if(/\/shop\/checkout\/?$/.test(path))return 'checkout';
        if(path.includes('/shop/product/')||path.includes('/shop/buy-'))return 'product';
        return 'otherApple';
      };
      const observeResponse=(url,status,source)=>{
        try{
          const target=new URL(url,location.href);
          if(target.protocol==='https:'&&/(^|\.)apple\.com$/i.test(target.hostname)&&/\/shop\//.test(target.pathname)&&[403,429,541].includes(status)){
            if(blockingStatus===null){
              blockingStatus=status;blockingSource=source;
              // Apple may immediately replace this document after its consumer sees
              // the original response. Retain only fixed classifications before that.
              try{window.webkit?.messageHandlers?.pickupPilotChanged?.postMessage({
                kind:'checkoutResponse',status,source,route:responseRoute(target)});}catch(_){}
            }
            checkoutBlocked=true;changed();
          }
        }catch(_){}
      };
      const accept = (value,sequence) => {
        if(value&&typeof value==='object'){
          models.push({value,sequence});models.sort((a,b)=>a.sequence-b.sequence);
          if(models.length>8)models.shift();changed();
        }
      };
      const appleShopRequest=input=>{
        try{
          const source=typeof input==='string'||input instanceof URL?input:input?.url;
          if(typeof source!=='string'&&!(source instanceof URL))return false;
          const target=new URL(source,location.href);
          return target.protocol==='https:'&&/(^|\.)apple\.com$/i.test(target.hostname)&&
            !target.username&&!target.password&&(!target.port||target.port==='443')&&/\/shop(?:\/|$)/.test(target.pathname);
        }catch(_){return false;}
      };
      const originalFetch = window.fetch;
      window.fetch = async function(...args) {
        const tracked=appleShopRequest(args[0]);
        let finished=false,capturing=false;
        const finish=()=>{if(!finished){finished=true;if(tracked){pendingNetwork--;changed();}}};
        if(tracked){pendingNetwork++;changed();}
        try{
          const response = await originalFetch.apply(this, args);
          observeResponse(response.url,response.status,'fetch');
          if (appleShopRequest(response.url) && response.status>=200 && response.status<300 &&
              /json/.test(response.headers.get('content-type') || '')) {
            const sequence=++responseSequence;
            // Apple's consumer gets its unmodified response immediately. Automation
            // stays pending through clone capture, including the wait for headers.
            pendingModels++;capturing=true;changed();
            try{
              Promise.resolve(response.clone().json()).then(value=>accept(value,sequence),()=>{}).finally(()=>{pendingModels--;finish();changed();});
            }catch(_){pendingModels--;capturing=false;changed();}
          }
          return response;
        }finally{
          if(!capturing)finish();
        }
      };
      const xhrShopRequests=new WeakMap();
      const originalOpen=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(...args){
        const result=originalOpen.apply(this,args);
        // Retain only the classification, never request URLs or their session tokens.
        xhrShopRequests.set(this,appleShopRequest(args[1]));return result;
      };
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) {
        const tracked=xhrShopRequests.get(this)===true;
        let finished=false;
        const observeLoad=()=>{
          if(finished)return;
          observeResponse(this.responseURL,this.status,'xhr');
          const sequence=++responseSequence;
          try { if (appleShopRequest(this.responseURL)&&this.status>=200&&this.status<300) accept(this.responseType === 'json' ? this.response : JSON.parse(this.responseText),sequence); } catch (_) {}
          changed();
        };
        const finish=()=>{
          if(finished)return;
          finished=true;
          this.removeEventListener('load',observeLoad);
          this.removeEventListener('loadend',finish);
          if(tracked){pendingNetwork--;changed();}
        };
        if(tracked){pendingNetwork++;changed();}
        this.addEventListener('loadend',finish,{once:true});
        this.addEventListener('load',observeLoad,{once:true});
        try{return originalSend.apply(this,args);}catch(error){finish();throw error;}
      };
      const visible = e => !!e && e.getClientRects().length > 0 && !e.closest('[inert],[aria-hidden="true"]');
      const enabled = e => visible(e) && !e.disabled && !e.matches(':disabled') && !e.closest('[aria-disabled~="true" i]');
      const all = s => Array.from(document.querySelectorAll(s)).filter(visible);
      const q = s => all(s)[0];
      const autom = s => `[data-autom="${s}"]`;
      const value = e => e ? String(e.value ?? e.textContent ?? '').trim() : '';
      const click = e => { if (!enabled(e)) return false; e.click();changed(); return true; };
      // DOM rerenders and network hints never release a dispatched forward action.
      // A repeated same-phase control requires manual attention rather than another click.
      const forwarded=new Set();
      const forward=(element,phase,key)=>{
        const identity=phase+':'+key;
        if(!enabled(element)||forwarded.has(identity))return false;
        forwarded.add(identity);return click(element);
      };
      const set = (e, text) => {
        if (!enabled(e) || e.readOnly || e.value === text) return false;
        if(e.tagName==='SELECT'&&![...e.options].some(option=>option.value===text&&!option.disabled&&!option.closest('optgroup')?.disabled))return false;
        const prototype = e.tagName === 'SELECT' ? HTMLSelectElement.prototype : e.tagName==='TEXTAREA' ? HTMLTextAreaElement.prototype : e.tagName==='INPUT' ? HTMLInputElement.prototype : null;
        if(!prototype)return false;
        Object.getOwnPropertyDescriptor(prototype, 'value').set.call(e, text);
        e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true }));
        e.dispatchEvent(new FocusEvent('blur', { bubbles: true })); return true;
      };
      const single = selector => { const fields=all(selector);return fields.length===1?fields[0]:null; };
      const editableProfileField=field=>enabled(field)&&!field.readOnly&&
        (field.tagName==='SELECT'||field.tagName==='TEXTAREA'||
         (field.tagName==='INPUT'&&['text','email','tel','number','password','search'].includes(field.type)));
      const normalizedProfileValue=(text,kind)=>{
        if(typeof text!=='string'||!text.trim())return null;
        if(kind==='cardNumber'){
          const digits=text.replace(/[\s-]/g,'');return /^[0-9]{13,19}$/.test(digits)?digits:null;
        }
        if(kind==='securityCode')return /^[0-9]{3,4}$/.test(text.trim())?text.trim():null;
        if(kind==='expiration'){
          const match=/^\s*([0-9]{1,2})\s*\/\s*([0-9]{2}|[0-9]{4})\s*$/.exec(text);
          return match&&+match[1]>=1&&+match[1]<=12?`${+match[1]}/${+match[2]%100}`:null;
        }
        if(kind==='phone'){
          const digits=text.replace(/[+()\s-]/g,'');return /^[0-9]{7,15}$/.test(digits)?digits:null;
        }
        if(kind==='phoneAreaCode'||kind==='phoneLocal'){
          const digits=text.replace(/[()\s-]/g,'');return (kind==='phoneAreaCode'?/^[0-9]{3}$/:/^[0-9]{7}$/).test(digits)?digits:null;
        }
        if(kind==='postalCode')return text.replace(/\s/g,'').toUpperCase();
        if(kind==='country'||kind==='region')return text.trim().toUpperCase();
        return text.trim();
      };
      const profileKind=key=>['mobilePhone','phoneNumber'].includes(key)?'phone':
        key==='postalCode'?'postalCode':key==='country'?'country':['state','province'].includes(key)?'region':'text';
      const profileMatches=(field,text,kind)=>{
        if(!editableProfileField(field))return false;
        if(field.tagName==='SELECT'&&(field.selectedOptions.length!==1||field.selectedOptions[0].disabled||field.selectedOptions[0].closest('optgroup')?.disabled))return false;
        const expected=normalizedProfileValue(text,kind),actual=normalizedProfileValue(field.value,kind);
        return expected!==null&&actual===expected;
      };
      const fillProfileField=(field,text,kind)=>editableProfileField(field)&&normalizedProfileValue(text,kind)!==null&&
        !profileMatches(field,text,kind)&&set(field,text);
      const splitNorthAmericanPhone=(text,marketPath)=>{
        if(!['/ca',''].includes(marketPath)||typeof text!=='string')return null;
        let digits=text.trim().replace(/[()\s-]/g,'');
        if(/^\+1[0-9]{10}$/.test(digits))digits=digits.slice(2);
        else if(/^1[0-9]{10}$/.test(digits))digits=digits.slice(1);
        else if(!/^[0-9]{10}$/.test(digits))return null;
        // NANP area and exchange codes start at 2. Do not infer a country or discard extra digits.
        if(!/^[2-9][0-9]{2}[2-9][0-9]{6}$/.test(digits))return null;
        return {area:digits.slice(0,3),local:digits.slice(3)};
      };
      const traverse = (object, callback, depth = 0) => {
        if (!object || typeof object !== 'object' || depth > 18) return;
        callback(object); Object.values(object).forEach(v => traverse(v, callback, depth + 1));
      };
      let initialText=null,initialModel=null;
      const model = path => {
        const text=document.getElementById('init_data')?.textContent || 'null';
        if(text!==initialText){
          initialText=text;initialModel=null;
          try{initialModel=JSON.parse(text);}catch(_){}
        }
        const initial=initialModel;
        const candidates = [...models].reverse().map(record=>record.value); candidates.push(initial);
        for (const source of candidates) {
          for (const root of [source, source?.body, source?.data]) {
            const found = path.split('.').reduce((v,k) => v?.[k], root); if (found) return found;
          }
        }
        return null;
      };
      const unique = values => [...new Set(values.filter(v => v !== null && v !== undefined && v !== ''))];
      const adapterSKU='MW2Q3AM/A';
      const unscheduledLabel='Pickup after Apple confirms it is ready';
      const adapterPickup=payload=>payload?.allowsUnscheduledPickup===true&&payload.marketPath==='/ca'&&payload.sku===adapterSKU;
      // Absence of a dropdown is not evidence of unscheduled pickup. Reject every
      // known reservation field (even null or malformed), plus unfamiliar timing
      // fields, while allowing Apple's empty display-only timeslot string.
      const reservationFree=(object,module=false)=>{
        if(!object||typeof object!=='object'||Array.isArray(object))return false;
        let nodes=0;
        const inspect=(value,depth=0)=>{
          if(++nodes>2000||depth>16)return false;
          if(!value||typeof value!=='object')return true;
          for(const [key,child] of Object.entries(value)){
            if(key==='timeslot'&&child==='')continue;
            if(module&&depth===0&&key==='timeSlot'){
              if(!child||typeof child!=='object'||Array.isArray(child)||Object.prototype.hasOwnProperty.call(child,'dateTimeSlots')||!inspect(child,depth+1))return false;
              continue;
            }
            if(/(?:startTime|endTime|checkIn|timeSlot|pickupTime|pickUpDate|dateTimeSlot|reservation|appointment|schedule|pickup.*(?:start|end|date|time|window)|(?:start|end).*pickup|^date$|^time$|timeZone|^window$)/i.test(key))return false;
            if(!inspect(child,depth+1))return false;
          }
          return true;
        };
        return inspect(object);
      };
      const iso = value => {
        if(typeof value!=='string')return null;
        const match=/^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?(Z|[+-](\d\d):(\d\d))$/.exec(value);
        if(!match||match[0]!==value)return null;
        const year=+match[1],month=+match[2],day=+match[3],hour=+match[4],minute=+match[5],second=+(match[6]||0);
        const leap=year%4===0&&(year%100!==0||year%400===0);
        const days=[31,leap?29:28,31,30,31,30,31,31,30,31,30,31];
        if(month<1||month>12||day<1||day>days[month-1]||hour>23||minute>59||second>59||+(match[8]||0)>23||+(match[9]||0)>59)return null;
        const date=new Date(value);return Number.isFinite(+date)?date.toISOString():null;
      };
      let privateBillingState=null,reviewStateID=null;
      const billingStateIdentity=review=>{
        const invalid=()=>{privateBillingState=null;reviewStateID=null;return null;};
        const billing=review?.billingReview,sections=all('.rs-review-billing');
        if(!billing||typeof billing!=='object'||Array.isArray(billing)||!Object.keys(billing).length||sections.length!==1)return invalid();
        const section=sections[0];
        // An opaque or competing payment surface cannot supply a review capability.
        if([...section.querySelectorAll('iframe')].some(visible))return invalid();
        try{
          let nodes=0;
          const canonical=(value,depth=0)=>{
            if(++nodes>10000||depth>24)throw new Error('unsupported billing state');
            if(value===null||typeof value==='string'||typeof value==='boolean')return value;
            if(typeof value==='number'&&Number.isFinite(value))return value;
            if(Array.isArray(value))return ['array',value.map(child=>canonical(child,depth+1))];
            if(value&&typeof value==='object')return ['object',Object.keys(value).sort().map(key=>[key,canonical(value[key],depth+1)])];
            throw new Error('unsupported billing state');
          };
          const text=[],fields=[],images=[],labels=[],selectionStates=[];
          const normalized=text=>String(text||'').replace(/\s+/g,' ').trim();
          const accessibleLabel=element=>[
            element.getAttribute('aria-label')||'',
            (element.getAttribute('aria-labelledby')||'').split(/\s+/).filter(Boolean).map(id=>normalized(document.getElementById(id)?.textContent)),
            [...(element.labels||[])].filter(visible).map(label=>normalized(label.textContent))
          ];
          const semantic=node=>{
            if(node.nodeType===Node.TEXT_NODE){text.push(node.nodeValue||'');return;}
            if(node.nodeType!==Node.ELEMENT_NODE||!visible(node)||node.matches('script,style,template,noscript,.waitindicator,[role="progressbar"]'))return;
            if(node.hasAttribute('role')||node.hasAttribute('aria-checked')||node.hasAttribute('aria-selected')||node.hasAttribute('aria-pressed')){
              selectionStates.push([node.tagName,node.getAttribute('role'),node.getAttribute('aria-checked'),node.getAttribute('aria-selected'),node.getAttribute('aria-pressed')]);
            }
            if(node.matches('input,select,textarea')){
              const options=node.tagName==='SELECT'?[...node.selectedOptions].map(option=>[option.value,normalized(option.textContent),normalized(option.label)]):[];
              fields.push([node.tagName,node.type||'',node.name||'',node.value,!!node.checked,!!node.indeterminate,options,accessibleLabel(node)]);return;
            }
            if(node.hasAttribute('aria-label')||node.hasAttribute('aria-labelledby'))labels.push(accessibleLabel(node));
            if(node.tagName==='IMG')images.push([node.getAttribute('alt')||'',node.getAttribute('src')||'']);
            for(const child of node.childNodes)semantic(child);
          };
          semantic(section);
          const visibleText=text.join('').replace(/\s+/g,' ').trim();
          if(!visibleText&&!fields.length&&!images.length)return invalid();
          // Raw billing/model/DOM values stay in this closure. Only a random nonce
          // crosses the native bridge; no payment text, account data or hash does.
          const state=JSON.stringify([canonical(billing),visibleText,fields,images,labels,selectionStates]);
          if(state!==privateBillingState){privateBillingState=state;reviewStateID=globalThis.crypto.randomUUID();}
          return reviewStateID;
        }catch(_){return invalid();}
      };
      const snapshot = () => {
        const finalButtons = all(autom('continue-button-placeOrder'));
        const form = q('form[data-part-number]');
        const review = model('checkout.review');
        const cart=model('shoppingCart');
        const productIDs=[], quantities=[];
        const itemRoots = [];
        const bagItems=finalButtons.length===0;
        const root = bagItems ? cart?.items : review?.fulfillmentReview;
        const collectItems=(v,depth=0)=>{
          if(!v||typeof v!=='object'||depth>12)return;
          if(bagItems){
            const aliases=[v.d?.productId,v.d?.partNumber,v.d?.sku].filter(value=>value!==null&&value!==undefined);
            if(aliases.length){
              const identifiers=aliases.every(value=>typeof value==='string'&&value.includes('/'))?unique(aliases):['UNVERIFIED-BAG-ITEM'];
              itemRoots.push({item:v,identifiers});return;
            }
          }else{
            const sku=v.d?.productId ?? v.d?.partNumber;
            if(typeof sku==='string'&&sku.includes('/')){itemRoots.push(v);return;}
          }
          for(const [key,child] of Object.entries(v)) {
            if(!['d','a','b','t','p','xMerch','recommendedSystemCartMoreProducts'].includes(key))collectItems(child,depth+1);
          }
        };
        collectItems(root);
        for (const record of itemRoots) {
          if(bagItems){
            const item=record.item;
            const current=[[item.itemQuantity?.d,'quantity'],[item.d,'quantity']].filter(([object,key])=>object&&Object.prototype.hasOwnProperty.call(object,key)).map(([object,key])=>object[key]);
            const legacy=typeof item.d?.productId==='string'||typeof item.d?.partNumber==='string';
            // originalQty is historical, not an alias for a present current quantity.
            // Its pre-existing fallback is retained only for the older item schema.
            const evidence=current.length?current:legacy&&Object.prototype.hasOwnProperty.call(item.d,'originalQty')?[item.d.originalQty]:[];
            const valid=evidence.length&&evidence.every(value=>(typeof value==='number'||typeof value==='string'&&/^[1-9][0-9]*$/.test(value))&&Number.isSafeInteger(Number(value))&&Number(value)>0);
            const amounts=valid?unique(evidence.map(Number)):[];
            const quantity=amounts.length===1?amounts[0]:0;
            for(const identifier of record.identifiers){productIDs.push(identifier);quantities.push(quantity);}
          }else{
            productIDs.push(record.d.productId ?? record.d.partNumber);
            const quantity=record.itemQuantity?.d?.quantity ?? record.d.quantity ?? record.d.originalQty;
            quantities.push(Number(quantity));
          }
        }
        if(bagItems&&root&&Object.prototype.hasOwnProperty.call(root,'c')){
          const records=new Set(itemRoots.map(record=>record.item));
          if(!Array.isArray(root.c)||new Set(root.c).size!==root.c.length||root.c.length!==records.size||
             root.c.some(reference=>typeof reference!=='string'||!Object.prototype.hasOwnProperty.call(root,reference)||!records.has(root[reference]))){
            productIDs.push('UNVERIFIED-BAG-ITEM');quantities.push(0);
          }
        }
        const storeIDs=[]; const starts=[]; const ends=[]; const slots=[];
        let pickupGroups=0, deliveryGroups=0, unscheduledGroups=0;
        traverse(review?.fulfillmentReview, v => {
          if (v.d?.delivers) deliveryGroups++;
          const p=v.d?.pickup; if (p) {
            pickupGroups++;
            storeIDs.push(p.storeNumber ?? p.storeId ?? p.retailStoreNumber);
            starts.push(iso(p.startTime ?? p.checkInStart)); ends.push(iso(p.endTime ?? p.checkInEnd));
            if (typeof p.timeslot === 'string') slots.push(p.timeslot.replace(/<[^>]*>/g, '').trim());
            if(reservationFree(p))unscheduledGroups++;
          }
        });
        let currency=null;
        try { const metrics=JSON.parse(document.getElementById('metrics')?.textContent || '{}'); currency=metrics.data?.properties?.currencyCode ?? metrics.data?.currency ?? null; } catch (_) {}
        const errors=all('[aria-invalid="true"],.is-error [role="alert"],.rs-messages-error').length > 0;
        const order = q('[data-autom="order-number"],[data-autom="orderNumber"],.rs-confirmation-ordernumber a');
        const hasChallenge=!!q('input[type="password"],input[autocomplete="one-time-code"],iframe[src*="captcha"],iframe[src*="challenge"]') || /\/(signIn|signin|verify|auth)\b/.test(location.pathname);
        // The bag HTML can finish loading before its cart model is initialized. A URL
        // is not cart evidence. Explicit state or item records still face the driver's
        // exact empty-bag/SKU/quantity checks, including contradictory or malformed data.
        const hasCartAuthority=typeof cart?.d?.hasItems==='boolean'||
          (cart?.items&&typeof cart.items==='object'&&Object.keys(cart.items).length>0);
        const pageNotFound=/^\/(?:[a-z]{2}\/)?shop\/(?:go\/)?404(?:\/|$)/.test(location.pathname)||
          (/\/shop\//.test(location.pathname)&&all('h1').some(heading=>
            /^(?:page not found|the page you're looking for can't be found)\.?$/i.test(
              String(heading.textContent||'').trim().replace(/[\u2018\u2019]/g,"'").replace(/\s+/g,' '))));
        let phase='unknown';
        if (pageNotFound) phase='pageNotFound';
        else if (checkoutBlocked) phase='blocked';
        else if (pendingModels>0||pendingNetwork>0) phase='loading';
        else if (hasChallenge) phase='authentication';
        else if (order && /thank|confirm|order_acknowledge/i.test(location.pathname)) phase='confirmation';
        else if (finalButtons.length) phase='review';
        else if (q(autom('continue-button-review'))) phase='payment';
        else if (q('.rs-pickup-contact-details')) phase='contact';
        else if (q(autom('fulfillment-continue-button'))) phase='fulfillment';
        else if (/\/shop\/bag(?:$|\/)/.test(location.pathname)) phase=hasCartAuthority?'bag':'loading';
        else if (form && q(autom('add-to-cart'))) phase='product';
        const billingIdentity=finalButtons.length?billingStateIdentity(review):null;
        const pickupIsUnscheduled=location.pathname.startsWith('/ca/shop/')&&productIDs.length===1&&productIDs[0]===adapterSKU&&
          quantities.length===1&&quantities[0]===1&&pickupGroups===1&&deliveryGroups===0&&unscheduledGroups===1;
        return {sourceURL:location.origin+location.pathname,documentID,reviewStateID:billingIdentity,phase,blockingStatus,blockingSource,productIDs,storeIDs:unique(storeIDs),quantities,
          totalText: finalButtons.length ? value(q(autom('orderTotalValue'))) || null : null,
          currencyCode:currency,pickupStartISO:unique(starts).length===1?unique(starts)[0]:null,
          pickupEndISO:unique(ends).length===1?unique(ends)[0]:null,pickupSlot:pickupIsUnscheduled?unscheduledLabel:unique(slots).length===1?unique(slots)[0]:null,
          pickupIsUnscheduled,
          orderID:order ? value(order) : null,finalActionCount:finalButtons.length,
          hasErrors:errors,pickupOnly:pickupGroups===1 && deliveryGroups===0,bagIsEmpty:phase==='bag' && cart?.d?.hasItems===false};
      };
      const instantFor = (date, time, zone) => {
        const direct=iso(time); if (direct) return direct;
        if (typeof date !== 'string' || typeof time !== 'string' || typeof zone !== 'string') return null;
        const d=date.match(/^(\d{4})-(\d\d)-(\d\d)$/), t=time.match(/^(\d\d?):(\d\d)(?::(\d\d))?$/);
        if (!d || d[0]!==date || !t || t[0]!==time || +t[1]>23 || +t[2]>59 || +(t[3]||0)>59) return null;
        try {
          const formatter=new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
          const desired=Date.UTC(+d[1],+d[2]-1,+d[3],+t[1],+t[2],+(t[3]||0)); let result=desired;
          const parts=x=>Object.fromEntries(formatter.formatToParts(new Date(x)).map(p=>[p.type,p.value]));
          for(let i=0;i<3;i++) {const p=parts(result);result+=desired-Date.UTC(+p.year,+p.month-1,+p.day,+p.hour,+p.minute,+p.second);}
          const p=parts(result); if (+p.year!==+d[1]||+p.month!==+d[2]||+p.day!==+d[3]||+p.hour!==+t[1]||+p.minute!==+t[2]) return null;
          return new Date(result).toISOString();
        } catch (_) { return null; }
      };
      const permitted = (instant,payload) => {
        const date=new Date(instant); if (+date<payload.pickupStart||+date>payload.pickupEnd) return false;
        try { const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:payload.timeZone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(date).map(p=>[p.type,p.value]));
          const minute=+p.hour*60 + +p.minute; return payload.startMinute<=payload.endMinute ? minute>=payload.startMinute&&minute<=payload.endMinute : minute>=payload.startMinute||minute<=payload.endMinute;
        } catch (_) { return false; }
      };
      const permittedInterval=(start,end,payload)=>{
        const first=+new Date(start),last=+new Date(end);
        if(!Number.isFinite(first)||!Number.isFinite(last)||last<=first||!permitted(start,payload)||!permitted(end,payload))return false;
        if(payload.startMinute===0&&payload.endMinute===1439)return true;
        if(last-first>26*60*60*1000)return false;
        for(let cursor=Math.floor(first/60000)*60000+60000;cursor<last;cursor+=60000){
          if(!permitted(new Date(cursor).toISOString(),payload))return false;
        }
        return true;
      };
      const authorizedNow=authorization=>{
        if(!authorization||!Number.isFinite(authorization.attemptStart)||!Number.isFinite(authorization.attemptEnd)||!Number.isFinite(authorization.reviewExpiresAt)||
           !Number.isInteger(authorization.startMinute)||!Number.isInteger(authorization.endMinute)||authorization.startMinute<0||authorization.endMinute<0||authorization.startMinute>1439||authorization.endMinute>1439||typeof authorization.timeZone!=='string')return false;
        const now=Date.now();
        if(now<authorization.attemptStart||now>authorization.attemptEnd||now>=authorization.reviewExpiresAt)return false;
        try{
          const parts=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:authorization.timeZone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(now)).map(part=>[part.type,part.value]));
          const minute=+parts.hour*60 + +parts.minute;
          return authorization.startMinute<=authorization.endMinute ? minute>=authorization.startMinute&&minute<=authorization.endMinute : minute>=authorization.startMinute||minute<=authorization.endMinute;
        }catch(_){return false;}
      };
      let added=false;
      let permitFinalClick=false, permitFinalForm=false, finalClickConsumed=false, finalFormConsumed=false;
      const finalSelector='[data-autom="continue-button-placeOrder"]';
      const reviewing=()=>all(finalSelector).length>0;
      if(submissionDisabled){
        new MutationObserver(()=>{
          for(const button of all(finalSelector)){button.disabled=true;button.setAttribute('aria-disabled','true');}
        }).observe(document,{childList:true,subtree:true});
      }
      document.addEventListener('click',event=>{
        if(event.target.closest?.(finalSelector)) {
          if(permitFinalClick)permitFinalClick=false;
          else {event.preventDefault();event.stopImmediatePropagation();}
        }
      },true);
      const permitForm=()=>{
        if(!reviewing())return true;
        if(!permitFinalForm||finalFormConsumed)return false;
        finalFormConsumed=true;return true;
      };
      document.addEventListener('submit',event=>{
        if(!permitForm()){event.preventDefault();event.stopImmediatePropagation();}
      },true);
      document.addEventListener('keydown',event=>{
        if(reviewing()&&(event.key==='Enter'||event.key===' ')){
          event.preventDefault();event.stopImmediatePropagation();
        }
      },true);
      const nativeSubmit=HTMLFormElement.prototype.submit;
      HTMLFormElement.prototype.submit=function(...args){if(permitForm())return nativeSubmit.apply(this,args);};
      const nativeRequestSubmit=HTMLFormElement.prototype.requestSubmit;
      if(nativeRequestSubmit)HTMLFormElement.prototype.requestSubmit=function(...args){
        if(reviewing()&&(!permitFinalForm||finalFormConsumed))return;
        return nativeRequestSubmit.apply(this,args);
      };
      const advance = payload => {
        const s=snapshot(); if(s.hasErrors) return false;
        if (s.phase==='product') {
          const f=q('form[data-part-number]'); if(f?.dataset.partNumber!==payload.sku||added) return false;
          for(const name of ['choose-noTradeIn','noapplecare','purchaseOptionFullPrice','unlocked']) {
            const e=q(autom(name)); if(e && !e.checked && e.getAttribute('aria-pressed')!=='true' && e.getAttribute('aria-selected')!=='true' && click(e)) return true;
          }
          const add=q(autom('add-to-cart')); if(enabled(add)) {added=true;return forward(add,s.phase,'add-to-cart');} return false;
        }
        if (s.phase==='bag') {
          if(s.productIDs.length!==1||s.productIDs[0]!==payload.sku||s.quantities.length!==1||s.quantities[0]!==1)return false;
          const normal=all('button[data-autom="checkout"]').filter(button=>button.type==='button');
          const main=normal.filter(button=>button.id==='shoppingCart.actions.checkout');
          const navigation=normal.filter(button=>button.id==='shoppingCart.actions.navCheckout');
          if(main.length>1||navigation.length>1)return false;
          const legacy=all(autom('bag-checkout-button')).find(button=>enabled(button)&&button.id!=='cart-actions-installmentCheckout'&&
            !button.closest('.rs-bag-installmentbutton,.rs-bag-installment-actions'));
          const button=enabled(main[0])?main[0]:enabled(navigation[0])?navigation[0]:legacy;
          // Main and navigation mirrors are one nonfinal checkout action, not two attempts.
          return forward(button,s.phase,'bag-checkout-button');
        }
        if (s.phase==='fulfillment') {
          const pickup=q('input[value="PICKUP"],input[value="RETAIL"]'); if(pickup&&!pickup.checked) return click(pickup);
          const stores=all(`input[name="store-locator-result"][value="${CSS.escape(payload.storeID)}"]`);
          if(stores.length>1)return false;
          const store=stores[0];
          if(!store) {const search=q(autom('bag-storelocator-input'));if(search&&payload.profile.searchLocation&&set(search,payload.profile.searchLocation)) return click(q(autom('fulfillment-pickup-store-search-button')));return false;}
          if(!enabled(store))return false;
          if(!store.checked) return click(store);
          if(all('input[name="store-locator-result"]').filter(input=>input.checked).length!==1)return false;
          const slotSelect=q(autom('pickup-availablewindow-dropdown'));
          if(slotSelect) {
            const section=model('checkout.fulfillment.pickupTab.pickup'); let chosen=null;
            traverse(section,v=>{if(!v.d?.pickUpDates||!v.d?.timeSlotWindows)return;
              for(const day of v.d.pickUpDates) for(const windows of v.d.timeSlotWindows) for(const slot of (windows[day.dayOfMonth]||[])) {
                const start=instantFor(day.date,slot.checkInStart,slot.timeZone),end=instantFor(day.date,slot.checkInEnd,slot.timeZone);
                if(slot.enabled===false||slot.isRestricted||!start||!end||!permittedInterval(start,end,payload))continue;
                if(!chosen||+new Date(start)<chosen.start)chosen={day,slot,start:+new Date(start)};
              }});
            if(!chosen)return false;
            const day=q(`input[name="bartPickupDateSelectorButtonGroup"][value="${CSS.escape(String(chosen.day.dayOfMonth))}"]`);
            if(!enabled(day))return false;
            if(!day.checked)return click(day);
            if(slotSelect.value!==chosen.slot.timeSlotValue)return set(slotSelect,chosen.slot.timeSlotValue);
          } else {
            const section=model('checkout.fulfillment.pickupTab.pickup');
            if(!adapterPickup(payload)||!section?.d||typeof section.d!=='object'||Array.isArray(section.d)||!reservationFree(section,true))return false;
          }
          return forward(q(autom('fulfillment-continue-button')),s.phase,'fulfillment-continue-button');
        }
        if(s.phase==='contact'||s.phase==='payment') {
          let changed=false;
          const areaSelector=autom('form-field-mobilePhoneAreaCode')+',input[name="mobilePhoneAreaCode"]';
          const localSelector=autom('form-field-mobilePhone')+',input[name="mobilePhone"]';
          const splitPhoneLayout=s.phase==='contact'&&all(areaSelector).length>0;
          for(const [key,text] of Object.entries(payload.profile)) {
            if(['cardNumber','expiration','securityCode','searchLocation'].includes(key))continue;
            if(splitPhoneLayout&&['mobilePhone','phoneNumber'].includes(key))continue;
            const field=single(autom(`form-field-${key}`)); if(field&&text)changed=fillProfileField(field,text,profileKind(key))||changed;
          }
          const matches=(keys,kind='text')=>keys.some(key=>profileMatches(single(autom(`form-field-${key}`)),payload.profile[key],kind));
          if(s.phase==='payment') {
            let cardReady=true;
            for(const [name,key] of [['card-number-input','cardNumber'],['expiration-input','expiration'],['security-code-input','securityCode']]) {
              const field=single(autom(name));
              if(field&&payload.profile[key])changed=fillProfileField(field,payload.profile[key],key)||changed;
              cardReady=profileMatches(field,payload.profile[key],key)&&cardReady;
            }
            const billingReady=matches(['cardholder'])&&matches(['street'])&&matches(['city'])&&matches(['country'],'country')&&
              (!payload.profile.street2?.trim()||matches(['street2']))&&
              (!payload.profile.postalCode?.trim()||matches(['postalCode'],'postalCode'))&&
              (!(payload.profile.province||payload.profile.state)?.trim()||matches(['province','state'],'region'));
            if(!cardReady||!billingReady)return false;
            if(changed)return true;
            return forward(q(autom('continue-button-review')),s.phase,'continue-button-review');
          }
          let phoneReady=matches(['mobilePhone','phoneNumber'],'phone');
          if(splitPhoneLayout){
            const phone=splitNorthAmericanPhone(payload.profile.mobilePhone,payload.marketPath);
            const area=single(areaSelector),local=single(localSelector);
            if(!phone||!area||!local||all(autom('form-field-phoneNumber')+',input[name="phoneNumber"]').length)return false;
            changed=fillProfileField(area,phone.area,'phoneAreaCode')||changed;
            changed=fillProfileField(local,phone.local,'phoneLocal')||changed;
            phoneReady=profileMatches(area,phone.area,'phoneAreaCode')&&profileMatches(local,phone.local,'phoneLocal');
          }
          if(!matches(['firstName'])||!matches(['lastName'])||!matches(['emailAddress','email'])||!phoneReady)return false;
          if(changed)return true;
          const buttons=all(autom('continue-button-label')).filter(enabled);return buttons.length===1&&forward(buttons[0],s.phase,'continue-button-label');
        }
        return false;
      };
      const acknowledgeManualInput=()=>{
        const current=snapshot();
        if(current.hasErrors||pendingModels>0||pendingNetwork>0||!['product','bag','fulfillment','contact','payment','review'].includes(current.phase))return false;
        // This is called only after the user's explicit Continue. Page signals and
        // field correction alone cannot grant a second same-phase forward action.
        for(const key of forwarded)if(key.startsWith(current.phase+':'))forwarded.delete(key);
        changed();return true;
      };
      const continueAsGuest=payload=>{
        const current=snapshot();
        if(checkoutBlocked||document.readyState!=='complete'||pendingModels>0||pendingNetwork>0||
           current.phase!=='authentication'||current.hasErrors||current.finalActionCount!==0||
           !documentID||payload?.documentID!==documentID||
           !/^(?:|\/[a-z]{2})$/.test(payload?.marketPath)||location.pathname!==payload.marketPath+'/shop/signIn')return false;
        // Never interact with security challenges or account/credential controls.
        if(q('input[autocomplete="one-time-code"],input[name*="captcha" i],input[name*="verification" i],iframe[src*="captcha" i],iframe[src*="challenge" i],[data-autom*="captcha" i]'))return false;
        const candidates=all('button,a,input[type="button"],input[type="submit"]').filter(element=>
          enabled(element)&&!element.matches(':disabled')&&
          !element.closest('[aria-disabled="true" i]')&&
          ['continue as guest','check out as guest'].includes(
            String(element.tagName==='INPUT'?element.value:element.textContent).replace(/\s+/g,' ').trim().toLowerCase()));
        return candidates.length===1&&forward(candidates[0],'authentication','guest-checkout');
      };
      const submit = (expected,authorization) => {
        if(submissionDisabled||finalClickConsumed||!authorizedNow(authorization))return false;
        if(!documentID||expected?.documentID!==documentID||!expected?.reviewStateID)return false;
        const actual=snapshot();
        // Re-read in the same JavaScript turn as the click, closing the native/browser race.
        for(const key of ['sourceURL','documentID','reviewStateID','phase','productIDs','storeIDs','quantities','totalText','currencyCode','pickupStartISO','pickupEndISO','pickupSlot','pickupIsUnscheduled','finalActionCount','hasErrors','pickupOnly']) {
          if(JSON.stringify(actual[key])!==JSON.stringify(expected[key]))return false;
        }
        if(actual.phase!=='review'||!actual.reviewStateID||actual.hasErrors||actual.finalActionCount!==1||!actual.pickupOnly)return false;
        const button=q(autom('continue-button-placeOrder'));
        if(!enabled(button)||!authorizedNow(authorization))return false;
        finalClickConsumed=true;permitFinalClick=true;permitFinalForm=true;
        try{return click(button);}finally{permitFinalClick=false;permitFinalForm=false;}
      };
      Object.defineProperty(window,'__pickupPilot',{value:Object.freeze({snapshot,advance,continueAsGuest,acknowledgeManualInput,submit}),writable:false,configurable:false});
    })();
    """#
}
