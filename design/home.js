(function(){
var MODES={cool:{l:'Kühlen',v:'Kühlt auf',c:'#4aa3ff'},heat:{l:'Heizen',v:'Heizt auf',c:'#ff8a3d'},auto:{l:'Automatik',v:'Automatik',c:'#5fd17a'},dry:{l:'Entfeuchten',v:'Entfeuchtet',c:'#3cc8c8'},fan:{l:'Lüften',v:'Lüftet',c:'#b8c2d6'}};
var FAN=['Auto','Leise','1','2','3','Turbo'];
var TIMER=['Aus','30 min','1 h','2 h'];
var TMIN=16,TMAX=30;
var SWATCHES=[{k:2200},{k:2700},{k:4000},{k:6500},{h:0,s:.85},{h:28,s:.9},{h:50,s:.8},{h:140,s:.6},{h:200,s:.75},{h:265,s:.7},{h:320,s:.6}];
var D=[
 {id:'klima',type:'climate',name:'Klimaanlage',icon:'ac',on:true,target:22,cur:24.1,mode:'cool',fan:'Auto',swing:true,eco:false,timer:'Aus'},
 {id:'decke',type:'light',name:'Deckenlicht',icon:'bulb',color:true,on:true,bri:80,mode:'white',k:3000,h:30,s:.6},
 {id:'steh',type:'light',name:'Stehlampe',icon:'bulb',color:true,on:false,bri:45,mode:'color',k:2700,h:28,s:.8},
 {id:'led',type:'light',name:'LED-Streifen TV',icon:'strip',color:true,on:true,bri:55,mode:'color',k:4000,h:265,s:.7},
 {id:'lese',type:'light',name:'Leselampe',icon:'bulb',color:false,on:false,bri:70,mode:'white',k:2700},
 {id:'rollo',type:'cover',name:'Rollo Terrasse',icon:'blind',pos:0},
 {id:'sonos',type:'media',name:'Sonos',icon:'speaker',on:false,vol:35,track:'Kerala',artist:'Bonobo'},
 {id:'film',type:'scene',name:'Filmabend',icon:'scene'},
 {id:'tuer',type:'lock',name:'Haustür',icon:'lock',on:true}
];
var SEC={klima:'Klima und Licht',rollo:'Weitere Geräte'};

function $(s,r){return (r||document).querySelector(s)}
function svg(n,c){return '<svg class="'+(c||'')+'" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-'+n+'"/></svg>'}
function clamp(v,a,b){return Math.max(a,Math.min(b,v))}
function tf(v){return (Math.round(v*2)/2).toFixed(1).replace('.0','').replace('.',',')+' °C'}
function hsv(h,s,v){var f=function(n){var k=(n+h/60)%6;return v-v*s*Math.max(0,Math.min(k,4-k,1))};return [f(5),f(3),f(1)].map(function(x){return Math.round(x*255)})}
function kelvin(k){var P=[[2200,[255,160,80]],[4000,[255,228,196]],[6500,[220,233,255]]];var a=k<=4000?P[0]:P[1],b=k<=4000?P[1]:P[2],t=(k-a[0])/(b[0]-a[0]);return a[1].map(function(x,i){return Math.round(x+(b[1][i]-x)*t)})}
function rgb(a){return 'rgb('+a.join(',')+')'}
function lightColor(d){return rgb(d.mode==='color'&&d.color?hsv(d.h,d.s,1):kelvin(d.k))}
function isOn(d){return d.type==='cover'?d.pos>0:d.type==='scene'?!!d.flash:!!d.on}
function accent(d){return d.type==='light'?lightColor(d):d.type==='climate'?MODES[d.mode].c:d.type==='lock'?'#34c759':'#ffb340'}
function status(d){
 if(d.type==='light')return d.on?d.bri+' %'+(d.color?(d.mode==='color'?' · Farbe':' · '+d.k+' K'):''):'Aus';
 if(d.type==='climate')return d.on?MODES[d.mode].v+(d.mode==='auto'||d.mode==='fan'?'':' '+tf(d.target)):'Aus';
 if(d.type==='cover')return d.pos===0?'Geschlossen':d.pos===100?'Offen':d.pos+' % offen';
 if(d.type==='media')return d.on?'Spielt · '+d.artist:'Pausiert';
 if(d.type==='scene')return d.flash?'Ausgeführt':'Szene';
 return d.on?'Verriegelt':'Entriegelt';
}
// Wert, den eine Wischgeste auf der Kachel verändert
var ADJ={light:['bri',0,100,1],climate:['target',TMIN,TMAX,.5],cover:['pos',0,100,1],media:['vol',0,100,1]};
function setVal(d,v){var a=ADJ[d.type];v=clamp(Math.round(v/a[3])*a[3],a[1],a[2]);d[a[0]]=v;
 if(d.type==='light')d.on=v>0;
 if(d.type==='climate'&&!d.on)d.on=true;
 changed(d)}
function toggle(d){
 if(d.type==='light'){d.on=!d.on;if(d.on&&d.bri===0)d.bri=50}
 else if(d.type==='cover')d.pos=d.pos>0?0:100;
 else if(d.type==='scene')return runScene(d);
 else d.on=!d.on;
 changed(d)}
function runScene(d){var m={decke:{on:false},steh:{on:true,bri:20,mode:'color',h:28,s:.8},led:{on:true,bri:40,mode:'color',h:240,s:.75},lese:{on:false},rollo:{pos:0}};
 D.forEach(function(x){if(m[x.id]){Object.assign(x,m[x.id]);changed(x)}});
 d.flash=true;changed(d);var el=tileEl(d);el.classList.add('flash');
 setTimeout(function(){d.flash=false;el.classList.remove('flash');changed(d)},1600)}

// ---------- Kacheln ----------
var grid=$('#grid');
function tileEl(d){return $('[data-id="'+d.id+'"]',grid)}
function build(){
 grid.innerHTML=D.map(function(d){
  var h=SEC[d.id]?'<div class="sec">'+SEC[d.id]+'</div>':'';
  var ico='<button class="ico" aria-label="'+d.name+' ein- oder ausschalten">'+svg(d.icon)+'</button>';
  if(d.type==='climate')return h+'<div class="tile big glass" data-id="'+d.id+'" tabindex="0" role="button" aria-label="'+d.name+', Details öffnen"><div class="fill"></div>'+
   '<div class="head">'+ico+'<div class="txt"><div class="n">'+d.name+'</div><div class="s"></div></div></div>'+
   '<div class="temp"><span class="tv"></span><small class="cur"></small></div>'+
   '<div class="track" aria-hidden="true"><div class="tf"></div><span class="lim l">'+TMIN+'°</span><span class="lim r">'+TMAX+'°</span><div class="th"></div></div></div>';
  return h+'<div class="tile glass" data-id="'+d.id+'" tabindex="0" role="button" aria-label="'+d.name+(ADJ[d.type]?', Details öffnen, Pfeiltasten regeln':'')+'"><div class="fill"></div>'+ico+
   '<div class="txt"><div class="n">'+d.name+'</div><div class="s"></div></div></div>';
 }).join('');
 D.forEach(function(d){bind(tileEl(d),d);paint(d)});
}
function paint(d){
 var el=tileEl(d),on=isOn(d),acc=accent(d);
 el.classList.toggle('on',on);
 $('.s',el).textContent=status(d);
 $('.ico',el).style.background=on?acc:'';
 var f=$('.fill',el);
 if(d.type==='light'){f.style.width=d.on?d.bri+'%':0;f.style.background=acc}
 else if(d.type==='cover'){f.style.width=d.pos+'%';f.style.background='#ffb340'}
 else f.style.width=0;
 if(d.type==='climate'){
  var p=(d.target-TMIN)/(TMAX-TMIN)*100;
  $('.tv',el).textContent=tf(d.target);
  $('.cur',el).textContent='Innen '+tf(d.cur);
  $('.tf',el).style.cssText='width:calc('+p+'% + 12px);background:'+(d.on?acc:'#ffffff40');
  $('.th',el).style.left='calc(12px + (100% - 24px) * '+p/100+')';
 }
}
function bind(el,d){
 var st=null;
 el.addEventListener('pointerdown',function(e){
  if(e.button)return;
  var tr=e.target.closest('.track');
  st={x:e.clientX,drag:false,ico:!!e.target.closest('.ico'),w:el.getBoundingClientRect().width,v:ADJ[d.type]?d[ADJ[d.type][0]]:0,track:tr?tr.getBoundingClientRect():null};
  if(st.track){st.drag=true;absTrack(e)}
  el.setPointerCapture(e.pointerId);
 });
 function absTrack(e){var r=st.track,p=clamp((e.clientX-r.left-12)/(r.width-24),0,1);setVal(d,TMIN+p*(TMAX-TMIN))}
 el.addEventListener('pointermove',function(e){
  if(!st)return;var dx=e.clientX-st.x;
  if(!st.drag&&Math.abs(dx)>6&&ADJ[d.type])st.drag=true;
  if(!st.drag)return;
  if(st.track)return absTrack(e);
  var a=ADJ[d.type];setVal(d,st.v+dx/st.w*(a[2]-a[1]));
 });
 el.addEventListener('pointerup',function(){
  if(!st)return;var s=st;st=null;
  if(s.drag)return;
  if(s.ico)toggle(d);else tap(d);
 });
 el.addEventListener('pointercancel',function(){st=null});
 el.addEventListener('keydown',function(e){
  if(e.target!==el)return;
  if(e.key==='Enter'||e.key===' '){e.preventDefault();tap(d)}
  var a=ADJ[d.type];if(!a)return;
  if(e.key==='ArrowRight'||e.key==='ArrowUp'){e.preventDefault();setVal(d,d[a[0]]+(a[3]===1?5:.5))}
  if(e.key==='ArrowLeft'||e.key==='ArrowDown'){e.preventDefault();setVal(d,d[a[0]]-(a[3]===1?5:.5))}
 });
 $('.ico',el).addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();e.stopPropagation();toggle(d)}});
}
function tap(d){if(d.type==='scene'||d.type==='lock')toggle(d);else open(d)}

// ---------- Detail-Sheet ----------
var scrim=$('#scrim'),sheet=$('#sheet'),cur=null,lastFocus=null;
function open(d){
 cur=d;lastFocus=document.activeElement;
 sheet.innerHTML='<div class="sh-head"><div class="ico">'+svg(d.icon)+'</div><div class="t"><b id="sh-title">'+d.name+'</b><small class="sh-st"></small></div>'+
  '<button class="sw" role="switch" aria-label="'+d.name+' Ein/Aus"></button><button class="x" aria-label="Schließen">'+svg('x','i')+'</button></div>'+body(d);
 scrim.hidden=false;
 wire(d);sync();
 $('.x',sheet).focus();
}
function close(){scrim.hidden=true;cur=null;sheet.innerHTML='';if(lastFocus&&lastFocus.focus)lastFocus.focus()}
scrim.addEventListener('pointerdown',function(e){if(e.target===scrim)close()});
document.addEventListener('keydown',function(e){if(e.key==='Escape'&&cur)close()});

function vs(k,label){return '<div class="vs" data-k="'+k+'" tabindex="0" role="slider" aria-label="'+label+'" aria-valuemin="0" aria-valuemax="100"><div class="vf"></div><span class="vl"></span></div>'}
function chips(name,list,labels){return '<div class="chips" data-g="'+name+'">'+list.map(function(v,i){return '<button class="chipb" data-v="'+v+'">'+(labels?labels[i]:v)+'</button>'}).join('')+'</div>'}
function body(d){
 if(d.type==='light'){
  var col=d.color?'<div class="seg" data-g="mode"><button data-v="color">Farbe</button><button data-v="white">Weißtöne</button></div>'+
   '<div class="wheelbox" data-p="color"><canvas width="440" height="440" aria-label="Farbrad"></canvas><i class="mark"></i></div>':'';
  return '<div class="sh-body">'+vs('bri','Helligkeit')+'<div class="col">'+col+
   '<div data-p="white" style="display:flex;flex-direction:column;gap:8px"><div class="kbar" aria-label="Farbtemperatur"><i class="mark"></i></div><div class="klbl"><span>Warm · 2200 K</span><span>Kalt · 6500 K</span></div></div>'+
   '<div class="lbl">Favoriten</div><div class="swatches">'+SWATCHES.filter(function(s){return d.color||s.k}).map(function(s,i){return '<button class="swatch" data-i="'+SWATCHES.indexOf(s)+'" aria-label="'+(s.k?s.k+' Kelvin':'Farbe '+(i+1))+'" style="background:'+(s.k?rgb(kelvin(s.k)):rgb(hsv(s.h,s.s,1)))+'"></button>'}).join('')+'</div>'+
   '<div class="lbl">Helligkeit</div>'+chips('bri',[100,60,30,5],['Hell','Normal','Gemütlich','Nachtlicht'])+
   '</div></div>';
 }
 if(d.type==='climate'){
  return '<div class="sh-body"><div class="dialbox"><svg class="dial" viewBox="0 0 260 260" role="slider" tabindex="0" aria-label="Zieltemperatur" aria-valuemin="'+TMIN+'" aria-valuemax="'+TMAX+'">'+
   '<path class="trk" d="'+arc(TMAX)+'" fill="none" stroke-width="18" stroke-linecap="round"/><path class="prg" fill="none" stroke-width="18" stroke-linecap="round"/><circle class="thumb" r="13"/></svg>'+
   '<div class="dc"><small class="dm"></small><b class="dv"></b><small>Innen '+tf(d.cur)+' · 48 % Feuchte</small></div>'+
   '<div class="pm"><button data-step="-0.5" aria-label="Kälter">−</button><button data-step="0.5" aria-label="Wärmer">+</button></div></div>'+
   '<div class="col"><div class="lbl">Modus</div><div class="chips" data-g="mode">'+Object.keys(MODES).map(function(m){return '<button class="chipb" data-v="'+m+'"><span class="dot" style="background:'+MODES[m].c+'"></span>'+MODES[m].l+'</button>'}).join('')+'</div>'+
   '<div class="lbl">Lüfter</div><div class="seg" data-g="fan">'+FAN.map(function(f){return '<button data-v="'+f+'">'+f+'</button>'}).join('')+'</div>'+
   '<div class="lbl">Ausschalten in</div><div class="seg" data-g="timer">'+TIMER.map(function(f){return '<button data-v="'+f+'">'+f+'</button>'}).join('')+'</div>'+
   '<div><div class="opt">Lamellen schwenken<button class="sw" data-b="swing" role="switch" aria-label="Lamellen schwenken"></button></div>'+
   '<div class="opt">Eco-Modus<button class="sw" data-b="eco" role="switch" aria-label="Eco-Modus"></button></div></div></div></div>';
 }
 if(d.type==='cover')return '<div class="sh-body">'+vs('pos','Position')+'<div class="col"><div class="lbl">Steuerung</div>'+chips('pos',[100,50,0],['Öffnen','Halb','Schließen'])+
  '<div class="lbl">Automatik</div><div class="opt">Bei Sonnenuntergang schließen<button class="sw" data-b="sunset" role="switch" aria-label="Bei Sonnenuntergang schließen"></button></div></div></div>';
 return '<div class="sh-body">'+vs('vol','Lautstärke')+'<div class="col"><div class="np"><div class="cover"></div><div><b>'+d.track+'</b><small>'+d.artist+'</small></div></div>'+
  '<div class="chips"><button class="chipb" data-act="prev" aria-label="Zurück">'+svg('prev','i')+'</button><button class="chipb" data-act="play"></button><button class="chipb" data-act="next" aria-label="Weiter">'+svg('next','i')+'</button></div></div></div>';
}
function wire(d){
 $('.sh-head .sw',sheet).addEventListener('click',function(){toggle(d)});
 $('.x',sheet).addEventListener('click',close);
 sheet.querySelectorAll('.vs').forEach(function(el){
  var k=el.dataset.k;
  drag(el,function(e){var r=el.getBoundingClientRect();var v=clamp((r.bottom-e.clientY)/r.height*100,0,100);
   if(k==='bri'){d.bri=Math.round(v);d.on=d.bri>0}else d[k]=Math.round(v);changed(d)});
  el.addEventListener('keydown',function(e){var s=e.key==='ArrowUp'||e.key==='ArrowRight'?5:e.key==='ArrowDown'||e.key==='ArrowLeft'?-5:0;if(!s)return;e.preventDefault();
   d[k]=clamp(d[k]+s,0,100);if(k==='bri')d.on=d.bri>0;changed(d)});
 });
 sheet.querySelectorAll('[data-g]').forEach(function(g){g.addEventListener('click',function(e){var b=e.target.closest('button');if(!b)return;
  var key=g.dataset.g,v=b.dataset.v;
  if(key==='bri'||key==='pos'){d[key]=+v;if(key==='bri')d.on=true}else d[key]=v;
  if(d.type==='climate'&&key==='mode')d.on=true;
  changed(d)})});
 sheet.querySelectorAll('[data-b]').forEach(function(b){b.addEventListener('click',function(){d[b.dataset.b]=!d[b.dataset.b];changed(d)})});
 sheet.querySelectorAll('.swatch').forEach(function(b){b.addEventListener('click',function(){var s=SWATCHES[b.dataset.i];
  if(s.k){d.mode='white';d.k=s.k}else{d.mode='color';d.h=s.h;d.s=s.s}d.on=true;if(!d.bri)d.bri=50;changed(d)})});
 var wb=$('.wheelbox',sheet);
 if(wb){drawWheel($('canvas',wb));drag(wb,function(e){var r=wb.getBoundingClientRect(),x=e.clientX-r.left-r.width/2,y=e.clientY-r.top-r.height/2;
  d.h=(Math.atan2(y,x)*180/Math.PI+360)%360;d.s=clamp(Math.hypot(x,y)/(r.width/2),0,1);d.mode='color';d.on=true;changed(d)})}
 var kb=$('.kbar',sheet);
 if(kb)drag(kb,function(e){var r=kb.getBoundingClientRect();d.k=Math.round((2200+clamp((e.clientX-r.left)/r.width,0,1)*4300)/50)*50;d.mode='white';d.on=true;changed(d)});
 var dial=$('.dial',sheet);
 if(dial){
  drag(dial,function(e){var r=dial.getBoundingClientRect(),x=e.clientX-r.left-r.width/2,y=e.clientY-r.top-r.height/2;
   var a=((Math.atan2(y,x)*180/Math.PI)-135+720)%360;if(a>270)a=a>315?0:270;setVal(d,TMIN+a/270*(TMAX-TMIN))});
  dial.addEventListener('keydown',function(e){var s=e.key==='ArrowUp'||e.key==='ArrowRight'?.5:e.key==='ArrowDown'||e.key==='ArrowLeft'?-.5:0;if(s){e.preventDefault();setVal(d,d.target+s)}});
  sheet.querySelectorAll('[data-step]').forEach(function(b){b.addEventListener('click',function(){setVal(d,d.target+ +b.dataset.step)})});
 }
 sheet.querySelectorAll('[data-act]').forEach(function(b){b.addEventListener('click',function(){if(b.dataset.act==='play'){d.on=!d.on;changed(d)}})});
}
function drag(el,fn){var on=false;
 el.addEventListener('pointerdown',function(e){on=true;el.setPointerCapture(e.pointerId);fn(e)});
 el.addEventListener('pointermove',function(e){if(on)fn(e)});
 el.addEventListener('pointerup',function(){on=false});el.addEventListener('pointercancel',function(){on=false})}
function arc(v){var a0=135,a1=135+(v-TMIN)/(TMAX-TMIN)*270,R=110,c=130;
 function pt(a){a=a*Math.PI/180;return (c+R*Math.cos(a)).toFixed(1)+' '+(c+R*Math.sin(a)).toFixed(1)}
 return 'M'+pt(a0)+' A'+R+' '+R+' 0 '+(a1-a0>180?1:0)+' 1 '+pt(Math.max(a1,a0+.01))}
function drawWheel(cv){var ctx=cv.getContext('2d'),n=cv.width,R=n/2,img=ctx.createImageData(n,n);
 for(var y=0;y<n;y++)for(var x=0;x<n;x++){var dx=x-R,dy=y-R,r=Math.hypot(dx,dy)/R,i=(y*n+x)*4;if(r>1)continue;
  var c=hsv((Math.atan2(dy,dx)*180/Math.PI+360)%360,r,1);img.data[i]=c[0];img.data[i+1]=c[1];img.data[i+2]=c[2];img.data[i+3]=255}
 ctx.putImageData(img,0,0)}
function sync(){
 var d=cur;if(!d)return;
 $('.sh-st',sheet).textContent=status(d);
 var sw=$('.sh-head .sw',sheet);sw.setAttribute('aria-checked',isOn(d));
 $('.sh-head .ico',sheet).style.background=isOn(d)?accent(d):'';
 sheet.querySelectorAll('.vs').forEach(function(el){var v=el.dataset.k==='bri'&&!d.on?0:d[el.dataset.k];
  $('.vf',el).style.height=v+'%';var l=$('.vl',el);l.textContent=v+' %';l.classList.toggle('up',v<14);el.setAttribute('aria-valuenow',v);
  if(d.type==='light')$('.vf',el).style.background=d.on?'linear-gradient(0deg,'+lightColor(d)+',#fff 140%)':''});
 sheet.querySelectorAll('[data-g]').forEach(function(g){g.querySelectorAll('button').forEach(function(b){b.setAttribute('aria-pressed',String(d[g.dataset.g])===b.dataset.v)})});
 sheet.querySelectorAll('[data-b]').forEach(function(b){b.setAttribute('aria-checked',!!d[b.dataset.b])});
 if(d.type==='light'){
  var wb=$('.wheelbox',sheet),wp=$('[data-p="white"]',sheet);
  if(wb){wb.hidden=d.mode!=='color';var m=$('.mark',wb);m.style.left=(50+Math.cos(d.h*Math.PI/180)*d.s*50)+'%';m.style.top=(50+Math.sin(d.h*Math.PI/180)*d.s*50)+'%';m.style.background=rgb(hsv(d.h,d.s,1))}
  wp.hidden=d.color&&d.mode==='color';
  var km=$('.kbar .mark',sheet);km.style.left=((d.k-2200)/4300*100)+'%';km.style.background=rgb(kelvin(d.k));
  sheet.querySelectorAll('.swatch').forEach(function(b){var s=SWATCHES[b.dataset.i];b.setAttribute('aria-pressed',s.k?d.mode==='white'&&d.k===s.k:d.mode==='color'&&Math.abs(d.h-s.h)<1&&Math.abs(d.s-s.s)<.01)});
 }
 if(d.type==='climate'){
  var col=d.on?MODES[d.mode].c:'#ffffff55',a=135+(d.target-TMIN)/(TMAX-TMIN)*270,rad=a*Math.PI/180;
  var prg=$('.prg',sheet);prg.setAttribute('d',arc(d.target));prg.setAttribute('stroke',col);
  var t=$('.thumb',sheet);t.setAttribute('cx',130+110*Math.cos(rad));t.setAttribute('cy',130+110*Math.sin(rad));
  $('.dv',sheet).textContent=tf(d.target).replace(' °C','°');$('.dm',sheet).textContent=d.on?MODES[d.mode].v:'Aus';
  $('.dial',sheet).setAttribute('aria-valuenow',d.target);
 }
 if(d.type==='media'){var p=$('[data-act="play"]',sheet);p.innerHTML=svg(d.on?'pause':'play','i');p.setAttribute('aria-label',d.on?'Pause':'Abspielen');p.setAttribute('aria-pressed',d.on)}
}

// ---------- Kopfzeile ----------
function stats(){
 var lights=D.filter(function(d){return d.type==='light'&&d.on}).length,k=D[0],door=D.filter(function(d){return d.type==='lock'})[0];
 $('#st-light').textContent=lights?lights+' an':'Alle aus';
 $('#st-clim').textContent=k.on?MODES[k.mode].l+' · '+tf(k.target):'Aus';
 $('#st-sec').textContent=door.on?'Verriegelt':'Haustür offen';
 $('#t-sub').textContent=D.filter(isOn).length+' Geräte an · Innen '+tf(k.cur);
}
function changed(d){paint(d);if(cur===d)sync();stats()}

function clock(){var n=new Date();$('#clock').firstChild.nodeValue=n.toLocaleTimeString('de-DE',{hour:'2-digit',minute:'2-digit'});
 $('#date').textContent=n.toLocaleDateString('de-DE',{weekday:'long',day:'numeric',month:'long'})}
var say=$('#say');
$('#mic').addEventListener('click',function(){say.hidden=!say.hidden;if(!say.hidden){var d=D[1];d.bri=30;d.on=true;changed(d)}});

build();stats();clock();setInterval(clock,20000);
})();
