package display;

class LevelRender extends dn.Process {
	static var FIELD_TEXT_SCALE : Float = 1.0;

	public var editor(get,never) : Editor; inline function get_editor() return Editor.ME;
	public var camera(get,never) : display.Camera; inline function get_camera() return Editor.ME.camera;
	public var settings(get,never) : AppSettings; inline function get_settings() return App.ME.settings;

	var autoLayerRendering = true;

	/** <LayerDefUID, Bool> **/
	var layerVis : Map<Int,Bool> = new Map();

	var layersWrapper : h2d.Layers;

	/** <LayerDefUID, LayerRender> **/
	var layerRenders : Map<Int, LayerRender> = new Map();

	/** <LayerDefUID, EntityRender> **/
	var entityRenders : Map<Int, Array<EntityRender> > = new Map();

	var bg : h2d.Bitmap;
	var bounds : h2d.Graphics;
	var boundsGlow : h2d.Graphics;
	var grid : h2d.Graphics;
	var rectBleeps : Array<h2d.Object> = [];
	public var temp : h2d.Graphics;

	// Invalidation system (ie. render calls)
	var allInvalidated = true;
	var uiInvalidated = false;
	var layerInvalidations : Map<Int, { left:Int, right:Int, top:Int, bottom:Int }> = new Map();


	public function new() {
		super(editor);

		editor.ge.addGlobalListener(onGlobalEvent);
		createRootInLayers(editor.root, Const.DP_MAIN);

		bg = new h2d.Bitmap();
		root.add(bg, Const.DP_BG);

		bounds = new h2d.Graphics();
		root.add(bounds, Const.DP_UI);

		boundsGlow = new h2d.Graphics();
		root.add(boundsGlow, Const.DP_UI);

		grid = new h2d.Graphics();
		root.add(grid, Const.DP_UI);

		layersWrapper = new h2d.Layers();
		root.add(layersWrapper, Const.DP_MAIN);

		temp = new h2d.Graphics();
		root.add(temp, Const.DP_TOP);
	}

	override function onDispose() {
		super.onDispose();
		editor.ge.removeListener(onGlobalEvent);
	}

	function onGlobalEvent(e:GlobalEvent) {
		switch e {
			case WorldMode(active):
				if( active ) {
					// Remove hidden render
					for(l in layerRenders)
						l.dispose();
					layerRenders = new Map();
					for(layerDefUid in entityRenders.keys())
						clearLayerEntities(layerDefUid);
					grid.clear();

					// Stop process
					pause();
					root.visible = false;
				}
				else {
					// Resume
					root.visible = true;
					invalidateAll();
					resume();
				}

			case GridChanged(active):
				applyGridVisibility();

			case ViewportChanged, WorldLevelMoved, WorldSettingsChanged:
				root.setScale( camera.adjustedZoom );
				root.x = M.round( editor.camera.width*0.5 - camera.levelX * camera.adjustedZoom );
				root.y = M.round( editor.camera.height*0.5 - camera.levelY * camera.adjustedZoom );

			case ProjectSaved, BeforeProjectSaving:

			case ProjectSelected:
				renderAll();

			case ProjectSettingsChanged:
				invalidateUi();

			case LevelRestoredFromHistory(l):
				invalidateAll();

			case LayerInstanceRestoredFromHistory(li):
				invalidateLayer(li);

			case LevelSelected(l):
				invalidateAll();

			case LevelResized(l):
				for(li in l.layerInstances)
					if( li.def.isAutoLayer() )
						li.applyAllAutoLayerRules();
				invalidateAll();

			case LayerInstanceVisiblityChanged(li):
				applyLayerVisibility(li);

			case AutoLayerRenderingChanged:
				for(li in editor.curLevel.layerInstances)
					if( li.def.isAutoLayer() )
						invalidateLayer(li);

			case LayerInstanceSelected:
				applyAllLayersVisibility();
				invalidateUi();

			case LevelSettingsChanged(l):
				invalidateUi();

			case LayerDefRemoved(uid):
				if( layerRenders.exists(uid) ) {
					layerRenders.get(uid).dispose();
					layerRenders.remove(uid);
					for(li in editor.curLevel.layerInstances)
						if( !li.def.autoLayerRulesCanBeUsed() )
							invalidateLayer(li);
				}
				clearLayerEntities(uid);

			case LayerDefSorted:
				for( li in editor.curLevel.layerInstances ) {
					var depth = editor.project.defs.getLayerDepth(li.def);
					if( layerRenders.exists(li.layerDefUid) )
						layersWrapper.add( layerRenders.get(li.layerDefUid).root, depth );
				}

			case LayerDefChanged, LayerDefConverted:
				invalidateAll();

			case LayerRuleChanged(r), LayerRuleAdded(r):
				var li = editor.curLevel.getLayerInstanceFromRule(r);
				li.applyAutoLayerRuleToAllLayer(r, true);
				invalidateLayer(li);

			case LayerRuleSeedChanged:
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleSorted:
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleRemoved(r):
				var li = editor.curLevel.getLayerInstanceFromRule(r);
				invalidateLayer( li==null ? editor.curLayerInstance : li );

			case LayerRuleGroupAdded:

			case LayerRuleGroupRemoved(rg):
				editor.curLayerInstance.applyAllAutoLayerRules();
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleGroupChanged(rg):
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleGroupChangedActiveState(rg):
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleGroupSorted:
				invalidateLayer( editor.curLayerInstance );

			case LayerRuleGroupCollapseChanged:

			case LayerInstanceChanged:

			case TilesetSelectionSaved(td):

			case TilesetDefPixelDataCacheRebuilt(td):

			case TilesetDefRemoved(td):
				invalidateAll();

			case TilesetDefChanged(td):
				for(li in editor.curLevel.layerInstances)
					if( li.def.isUsingTileset(td) )
						invalidateLayer(li);

			case TilesetDefAdded(td):

			case EntityDefRemoved, EntityDefChanged, EntityDefSorted:
				for(li in editor.curLevel.layerInstances)
					if( li.def.type==Entities )
						invalidateLayer(li);

			case EntityFieldAdded(ed), EntityFieldRemoved(ed), EntityFieldDefChanged(ed):
				if( editor.curLayerInstance!=null ) {
					var li = editor.curLevel.getLayerInstanceFromEntity(ed);
					invalidateLayer( li==null ? editor.curLayerInstance : li );
				}

			case EnumDefRemoved, EnumDefChanged, EnumDefValueRemoved:
				for(li in editor.curLevel.layerInstances)
					if( li.def.type==Entities )
						invalidateLayer(li);

			case EntityInstanceAdded(ei), EntityInstanceRemoved(ei), EntityInstanceChanged(ei), EntityInstanceFieldChanged(ei):
				var li = editor.curLevel.getLayerInstanceFromEntity(ei);
				invalidateLayer( li==null ? editor.curLayerInstance : li );

			case LevelAdded(l):

			case LevelRemoved(l):

			case LevelSorted:
			case LayerDefAdded:

			case EntityDefAdded:
			case EntityFieldSorted:

			case ToolOptionChanged:

			case EnumDefAdded:
			case EnumDefSorted:
		}
	}

	public inline function isAutoLayerRenderingEnabled() {
		return autoLayerRendering;
	}

	public function setAutoLayerRendering(v:Bool) {
		autoLayerRendering = v;
		editor.ge.emit( AutoLayerRenderingChanged );
	}

	public inline function toggleAutoLayerRendering() {
		setAutoLayerRendering( !autoLayerRendering );
		return autoLayerRendering;
	}

	public inline function isLayerVisible(l:data.inst.LayerInstance) {
		return l!=null && ( !layerVis.exists(l.layerDefUid) || layerVis.get(l.layerDefUid)==true );
	}

	public function toggleLayer(li:data.inst.LayerInstance) {
		layerVis.set(li.layerDefUid, !isLayerVisible(li));
		editor.ge.emit( LayerInstanceVisiblityChanged(li) );

		if( isLayerVisible(li) )
			invalidateLayer(li);
	}

	public function showLayer(li:data.inst.LayerInstance) {
		layerVis.set(li.layerDefUid, true);
		editor.ge.emit( LayerInstanceVisiblityChanged(li) );
	}

	public function hideLayer(li:data.inst.LayerInstance) {
		layerVis.set(li.layerDefUid, false);
		editor.ge.emit( LayerInstanceVisiblityChanged(li) );
	}

	public function bleepRectPx(x:Int, y:Int, w:Int, h:Int, col:UInt, thickness=1) {
		var pad = 5;
		var g = new h2d.Graphics();
		rectBleeps.push(g);
		g.lineStyle(thickness, col);
		g.drawRect( Std.int(-pad-w*0.5), Std.int(-pad-h*0.5), w+pad*2, h+pad*2 );
		g.setPosition(
			Std.int(x+w*0.5) + editor.curLayerInstance.pxTotalOffsetX,
			Std.int(y+h*0.5) + editor.curLayerInstance.pxTotalOffsetY
		);
		root.add(g, Const.DP_UI);
	}

	public inline function bleepRectCase(cx:Int, cy:Int, cWid:Int, cHei:Int, col:UInt, thickness=1) {
		var li = editor.curLayerInstance;
		bleepRectPx(
			cx*li.def.gridSize,
			cy*li.def.gridSize,
			cWid*li.def.gridSize,
			cHei*li.def.gridSize,
			col, 2
		);
	}

	public inline function bleepHistoryBounds(layerId:Int, bounds:HistoryStateBounds, col:UInt) {
		bleepRectPx(bounds.x, bounds.y, bounds.wid, bounds.hei, col, 2);
	}
	public inline function bleepEntity(ei:data.inst.EntityInstance) {
		bleepRectPx(
			Std.int( ei.x-ei.def.width*ei.def.pivotX ),
			Std.int( ei.y-ei.def.height*ei.def.pivotY ),
			ei.def.width,
			ei.def.height,
			ei.getSmartColor(true), 2
		);
	}

	public inline function bleepPoint(x:Float, y:Float, col:UInt, thickness=2) {
		var g = new h2d.Graphics();
		rectBleeps.push(g);
		g.lineStyle(thickness, col);
		g.drawCircle( 0,0, 16 );
		g.setPosition( M.round(x), M.round(y) );
		root.add(g, Const.DP_UI);
	}


	function renderBg() {
		var c = editor.curLevel.getBgColor();
		bg.tile = h2d.Tile.fromColor(c);
		bg.scaleX = editor.curLevel.pxWid;
		bg.scaleY = editor.curLevel.pxHei;
	}

	function renderBounds() {
		// Bounds
		bounds.clear();
		bounds.lineStyle(1, 0xffffff, 0.7);
		bounds.drawRect(0, 0, editor.curLevel.pxWid, editor.curLevel.pxHei);

		// Bounds glow/shadow
		boundsGlow.clear();
		boundsGlow.beginFill(0xff00ff);
		boundsGlow.drawRect(0, 0, editor.curLevel.pxWid, editor.curLevel.pxHei);
		var shadow = new h2d.filter.Glow( 0x0, 0.6, 128, true );
		shadow.knockout = true;
		boundsGlow.filter = shadow;
	}

	inline function applyGridVisibility() {
		grid.visible = settings.grid && !editor.worldMode;
	}

	function renderGrid() {
		grid.clear();
		applyGridVisibility();

		if( editor.curLayerInstance==null )
			return;

		var col = C.getPerceivedLuminosityInt( editor.project.bgColor) >= 0.8 ? 0x0 : 0xffffff;

		var li = editor.curLayerInstance;
		var level = editor.curLevel;
		grid.lineStyle(1, col, 0.07);

		// Verticals
		var x = 0;
		for( cx in 0...editor.curLayerInstance.cWid+1 ) {
			x = cx*li.def.gridSize + li.pxTotalOffsetX;
			if( x<0 || x>=level.pxWid )
				continue;

			grid.moveTo( x, M.fmax(0,li.pxTotalOffsetY) );
			grid.lineTo( x, M.fmin(li.cHei*li.def.gridSize, level.pxHei) );
		}
		// Horizontals
		var y = 0;
		for( cy in 0...editor.curLayerInstance.cHei+1 ) {
			y = cy*li.def.gridSize + li.pxTotalOffsetY;
			if( y<0 || y>=level.pxHei)
				continue;

			grid.moveTo( M.fmax(0,li.pxTotalOffsetX), y );
			grid.lineTo( M.fmin(li.cWid*li.def.gridSize, level.pxWid), y );
		}
	}


	public function renderAll() {
		allInvalidated = false;

		clearTemp();
		renderBounds();
		renderGrid();
		renderBg();

		for(ld in editor.project.defs.layers)
			renderLayer( editor.curLevel.getLayerInstance(ld) );
	}

	public inline function clearTemp() {
		temp.clear();
	}


	function renderLayer(li:data.inst.LayerInstance) {
		layerInvalidations.remove(li.layerDefUid);

		// Create wrapper
		if( layerRenders.exists(li.layerDefUid) )
			layerRenders.get(li.layerDefUid).dispose();

		var lr = new LayerRender(li, autoLayerRendering);

		// var wrapper = new h2d.Object();
		// wrapper.x = li.pxTotalOffsetX;
		// wrapper.y = li.pxTotalOffsetY;

		// Register it
		layerRenders.set(li.layerDefUid, lr);
		var depth = editor.project.defs.getLayerDepth(li.def);
		layersWrapper.add( lr.root, depth );

		/*
		// Render
		switch li.def.type {
		case IntGrid, AutoLayer:
			// var doneCoords = new Map();

			if( li.def.isAutoLayer() && li.def.autoTilesetDefUid!=null && autoLayerRendering ) {
				// Auto-layer tiles
				var td = editor.project.defs.getTilesetDef( li.def.autoTilesetDefUid );
				var tg = new h2d.TileGroup( td.getAtlasTile(), wrapper);

				if( li.autoTilesCache==null )
					li.applyAllAutoLayerRules();

				li.def.iterateActiveRulesInDisplayOrder( (r)-> {
					if( li.autoTilesCache.exists( r.uid ) ) {
						for(coordId in li.autoTilesCache.get( r.uid ).keys()) {
							// doneCoords.set(coordId, true);
							for(tileInfos in li.autoTilesCache.get( r.uid ).get(coordId)) {
								tg.addTransform(
									tileInfos.x + ( ( dn.M.hasBit(tileInfos.flips,0)?1:0 ) + li.def.tilePivotX ) * li.def.gridSize,
									tileInfos.y + ( ( dn.M.hasBit(tileInfos.flips,1)?1:0 ) + li.def.tilePivotY ) * li.def.gridSize,
									dn.M.hasBit(tileInfos.flips,0)?-1:1,
									dn.M.hasBit(tileInfos.flips,1)?-1:1,
									0,
									td.extractTile(tileInfos.srcX, tileInfos.srcY)
								);
							}
						}
					}
				});

				// Default render when no rule match here
				// if( li.def.type==IntGrid && !li.def.hasAnyActiveRule() ) {
				// 	for(cy in 0...li.cHei)
				// 	for(cx in 0...li.cWid) {
				// 		if( doneCoords.exists(li.coordId(cx,cy)) || li.getIntGrid(cx,cy)<0 )
				// 			continue;
				// 		g.lineStyle(1, li.getIntGridColorAt(cx,cy), 0.6 );
				// 		g.drawRect(cx*li.def.gridSize+2, cy*li.def.gridSize+2, li.def.gridSize-4, li.def.gridSize-4);
				// 	}
				// }
			}
			else if( li.def.type==IntGrid ) {
				// Normal intGrid
				var pixelGrid = new dn.heaps.PixelGrid(li.def.gridSize, li.cWid, li.cHei, wrapper);

				for(cy in 0...li.cHei)
				for(cx in 0...li.cWid)
					if( li.hasIntGrid(cx,cy) )
						pixelGrid.setPixel( cx, cy, li.getIntGridColorAt(cx,cy) );
			}

		case Entities:
			clearLayerEntities(li.layerDefUid);
			for(ei in li.entityInstances) {
				var er = new EntityRender(ei, li.def, wrapper);
				entityRenders.get(li.layerDefUid).push( er );
			}

		case Tiles:
			var td = editor.project.defs.getTilesetDef(li.def.tilesetDefUid);
			if( td!=null && td.isAtlasLoaded() ) {
				var tg = new h2d.TileGroup( td.getAtlasTile(), wrapper );

				for(cy in 0...li.cHei)
				for(cx in 0...li.cWid) {
					if( !li.hasAnyGridTile(cx,cy) )
						continue;

					for( tileInf in li.getGridTileStack(cx,cy) ) {
						var t = td.getTile(tileInf.tileId);
						t.setCenterRatio(li.def.tilePivotX, li.def.tilePivotY);
						var sx = M.hasBit(tileInf.flips, 0) ? -1 : 1;
						var sy = M.hasBit(tileInf.flips, 1) ? -1 : 1;
						tg.addTransform(
							(cx + li.def.tilePivotX + (sx<0?1:0)) * li.def.gridSize,
							(cy + li.def.tilePivotX + (sy<0?1:0)) * li.def.gridSize,
							sx,
							sy,
							0,
							t
						);
					}
				}
			}
			else {
				// Missing tileset
				var tileError = data.def.TilesetDef.makeErrorTile(li.def.gridSize);
				var tg = new h2d.TileGroup( tileError, wrapper );
				for(cy in 0...li.cHei)
				for(cx in 0...li.cWid)
					if( li.hasAnyGridTile(cx,cy) )
						tg.add(
							(cx + li.def.tilePivotX) * li.def.gridSize,
							(cy + li.def.tilePivotX) * li.def.gridSize,
							tileError
						);
			}
		}
		*/

		applyLayerVisibility(li);
	}


	function clearLayerEntities(layerDefUid:Int) {
		if( entityRenders.exists(layerDefUid) )
			for( er in entityRenders.get(layerDefUid) )
				er.destroy();

		entityRenders.set(layerDefUid, []);
	}


	function applyLayerVisibility(li:data.inst.LayerInstance) {
		var lr = layerRenders.get(li.layerDefUid);
		if( lr==null )
			return;

		lr.root.visible = isLayerVisible(li);
		lr.root.alpha = li.def.displayOpacity * ( !settings.singleLayerMode || li==editor.curLayerInstance ? 1 : 0.2 );
		lr.root.filter = !settings.singleLayerMode || li==editor.curLayerInstance ? null : new h2d.filter.Group([
			C.getColorizeFilterH2d(0x8c99c1, 0.9),
			new h2d.filter.Blur(2),
		]);
	}


	@:allow(page.Editor)
	function applyAllLayersVisibility() {
		for(ld in editor.project.defs.layers) {
			var li = editor.curLevel.getLayerInstance(ld);
			applyLayerVisibility(li);
		}
	}

	public inline function invalidateLayer(?li:data.inst.LayerInstance, ?layerDefUid:Int) {
		if( li==null )
			li = editor.curLevel.getLayerInstance(layerDefUid);
		layerInvalidations.set( li.layerDefUid, { left:0, right:li.cWid-1, top:0, bottom:li.cHei-1 } );

		if( li.def.type==IntGrid )
			for(l in editor.curLevel.layerInstances)
				if( l.def.type==AutoLayer && l.def.autoSourceLayerDefUid==li.def.uid )
					invalidateLayer(l);
	}

	public inline function invalidateLayerArea(li:data.inst.LayerInstance, left:Int, right:Int, top:Int, bottom:Int) {
		if( layerInvalidations.exists(li.layerDefUid) ) {
			var bounds = layerInvalidations.get(li.layerDefUid);
			bounds.left = M.imin(bounds.left, left);
			bounds.right = M.imax(bounds.right, right);
		}
		else
			layerInvalidations.set( li.layerDefUid, { left:left, right:right, top:top, bottom:bottom } );

		// Invalidate linked auto-layers
		if( li.def.type==IntGrid )
			for(other in editor.curLevel.layerInstances)
				if( other.def.type==AutoLayer && other.def.autoSourceLayerDefUid==li.layerDefUid )
					invalidateLayerArea(other, left, right, top, bottom);
	}

	public inline function invalidateUi() {
		uiInvalidated = true;
	}

	public inline function invalidateAll() {
		allInvalidated = true;
	}

	override function postUpdate() {
		super.postUpdate();

		// Fade-out temporary rects
		var i = 0;
		while( i<rectBleeps.length ) {
			var o = rectBleeps[i];
			o.alpha-=tmod*0.042;
			o.setScale( 1 + 0.2 * (1-o.alpha) );
			if( o.alpha<=0 ) {
				o.remove();
				rectBleeps.splice(i,1);
			}
			else
				i++;
		}


		// Render invalidation system
		if( allInvalidated ) {
			// Full
			renderAll();
			App.LOG.warning("Full render requested");
		}
		else {
			// UI & bg elements
			if( uiInvalidated ) {
				renderBg();
				renderBounds();
				renderGrid();
				uiInvalidated = false;
				App.LOG.render("Rendered level UI");
			}

			// Layers
			for( li in editor.curLevel.layerInstances )
				if( layerInvalidations.exists(li.layerDefUid) ) {
					var b = layerInvalidations.get(li.layerDefUid);
					if( li.def.isAutoLayer() )
						li.applyAllAutoLayerRulesAt( b.left, b.top, b.right-b.left+1, b.bottom-b.top+1 );
					renderLayer(li);
				}
		}

		applyGridVisibility();
	}

}
