TextHints =
  activateMode: () ->
    TextHintCoordinator.prepareToActivateMode (isSuccess) ->

TextHintCoordinator =
  onExit: []
  localHints: null
  suppressKeyboardEvents: null

  sendMessage: (messageType, request = {}) ->
    Frame.postMessage "textHintsMessage", extend request, {messageType}

  prepareToActivateMode: (onExit) ->
    # We need to communicate with the background page (and other frames) to initiate link-hints mode.  To
    # prevent other Vimium commands from being triggered before link-hints mode is launched, we install a
    # temporary mode to block keyboard events.
    @suppressKeyboardEvents = suppressKeyboardEvents = new SuppressAllKeyboardEvents
      name: "text-hints/suppress-keyboard-events"
      singleton: "text-hints-mode"
      indicator: "Collecting hints..."
      exitOnEscape: true
    # FIXME(smblott) Global link hints is currently insufficiently reliable.  If the mode above is left in
    # place, then Vimium blocks.  As a temporary measure, we install a timer to remove it.
    Utils.setTimeout 1000, -> suppressKeyboardEvents.exit() if suppressKeyboardEvents?.modeIsActive
    @onExit = [onExit]
    @sendMessage "prepareToActivateMode"

  getHintDescriptors: ({modeIndex, isVimiumHelpDialog}) ->
    DomUtils.documentReady => Settings.onLoaded =>
      @localHints = LocalTextHints.getLocalHints()
      @localHintDescriptors = @localHints.map ({linkText}, localIndex) -> {frameId, localIndex, linkText}
      @sendMessage "postHintDescriptors", hintDescriptors: @localHintDescriptors

  activateMode: ({hintDescriptors, modeIndex, originatingFrameId}) ->
    [hintDescriptors[frameId], @localHintDescriptors] = [@localHintDescriptors, null]
    hintDescriptors = [].concat (hintDescriptors[fId] for fId in (fId for own fId of hintDescriptors).sort())...

    DomUtils.documentReady => Settings.onLoaded =>
      @suppressKeyboardEvents.exit() if @suppressKeyboardEvents?.modeIsActive
      @suppressKeyboardEvents = null
      @onExit = [] unless frameId == originatingFrameId
      @textHintsMode = new TextHintsMode hintDescriptors

  # The following messages are exchanged between frames while text-hints mode is active.
  updateKeyState: (request) -> @textHintsMode.updateKeyState request
  getLocalHintMarker: (hint) -> if hint.frameId == frameId then @localHints[hint.localIndex] else null

  exit: ({isSuccess}) ->
    @textHintsMode?.deactivateMode()
    @onExit.pop() isSuccess while 0 < @onExit.length
    @textHintsMode = @localHints = null

LocalTextHints =
  getLocalHints: ->
    return [] unless document.documentElement

    walk = document.createTreeWalker document.body, NodeFilter.SHOW_TEXT
    textNodes = while node = walk.nextNode()
        node
    blackListedTags = ['STYLE', 'SCRIPT', 'NOSCRIPT']
    textNodes = textNodes.filter (node) -> node.nodeValue.trim().length > 0 && !(node.parentNode.tagName in blackListedTags)

    visibleElements = []
    for textNode in textNodes
        visibleElement = @getVisible textNode.parentNode
        visibleElements.push visibleElement if visibleElement.rect != null

    localHints = visibleElements

    {top, left} = DomUtils.getViewportTopLeft()
    for hint in localHints
      hint.rect.top += top
      hint.rect.left += left

    localHints

  getVisible: (element) ->
    clientRect = DomUtils.getVisibleClientRect element, true
    {element: element, rect: clientRect}

class TextHintsMode
  constructor: (hintDescriptors) ->
    return unless document.documentElement

    if hintDescriptors.length == 0
      HUD.showForDuration "No texts to select.", 2000
      return

    @hintMarkers = (@createMarkerFor desc for desc in hintDescriptors)
    @markerMatcher = new AlphabetHints
    @markerMatcher.fillInMarkers @hintMarkers, @.getNextZIndex.bind this

    @hintMode = new Mode
      name: "hint/text-hints-mode"
      indicator: false
      singleton: "text-hints-mode"
      passInitialKeyupEvents: true
      suppressAllKeyboardEvents: true
      suppressTrailingKeyEvents: true
      exitOnEscape: true
      exitOnClick: true
      keydown: @onKeyDownInMode.bind this
      keypress: @onKeyPressInMode.bind this

    @hintMode.onExit (event) =>
      if event?.type == "click" or (event?.type == "keydown" and
        (KeyboardUtils.isEscape(event) or event.keyCode in [keyCodes.backspace, keyCodes.deleteKey]))
          TextHintCoordinator.sendMessage "exit", isSuccess: false

    @hintMarkerContainingDiv = DomUtils.addElementList (marker for marker in @hintMarkers when marker.isLocalMarker),
      id: "vimiumHintMarkerContainer", className: "vimiumReset"
  #
  # Creates a link marker for the given text field.
  #
  createMarkerFor: (desc) ->
    marker =
      if desc.frameId == frameId
        localHintDescriptor = TextHintCoordinator.getLocalHintMarker desc
        el = DomUtils.createElement "div"
        el.rect = localHintDescriptor.rect
        el.style.left = el.rect.left + "px"
        el.style.top = el.rect.top  + "px"
        # Each hint marker is assigned a different z-index.
        el.style.zIndex = @getNextZIndex()
        extend el,
          className: "vimiumReset internalVimiumHintMarker vimiumHintMarker"
          showLinkText: localHintDescriptor.showLinkText
          localHintDescriptor: localHintDescriptor
      else
        {}

    extend marker,
      hintDescriptor: desc
      isLocalMarker: desc.frameId == frameId
      linkText: desc.linkText

  getNextZIndex: do ->
    # This is the starting z-index value; it produces z-index values which are greater than all of the other
    # z-index values used by Vimium.
    baseZIndex = 2140000000
    -> baseZIndex += 1

  # Handles <Shift> and <Ctrl>.
  onKeyDownInMode: (event) ->
    @keydownKeyChar = KeyboardUtils.getKeyChar(event).toLowerCase()

    previousTabCount = @tabCount
    @tabCount = 0

    # NOTE(smblott) As of 1.54, the Ctrl modifier doesn't work for filtered link hints; therefore we only
    # offer the control modifier for alphabet hints.  It is not clear whether we should fix this.  As of
    # 16-03-28, nobody has complained.
    modifiers = [keyCodes.shiftKey]
    if event.keyCode in [ keyCodes.leftArrow, keyCodes.rightArrow ]
        @handleTextSelection event

  # Handles normal input.
  onKeyPressInMode: (event) ->
    keyChar = String.fromCharCode(event.charCode).toLowerCase()
    if keyChar
      @markerMatcher.pushKeyChar keyChar, @keydownKeyChar
      @updateVisibleMarkers()

    # We've handled the event, so suppress it.
    DomUtils.suppressEvent event

  handleTextSelection: (event) ->
    # Don't bubble the event
    DomUtils.suppressEvent event
    selectedText = DomUtils.getSelectedText()

    if event.keyCode == keyCodes.leftArrow
      @handleLeftArrowSelection event.shiftKey, event.ctrlKey
    else if event.keyCode == keyCodes.rightArrow
      @handleRightArrowSelection event.shiftKey, event.ctrlKey

  handleRightArrowSelection: (shiftKey, ctrlKey) ->
    baseOffset = @selectionBaseOffset
    extentOffset = @selectionExtentOffset
    reverseSelect = extentOffset < baseOffset
    elementText = @getElementText @matchingElement

    if extentOffset == elementText.length
      return

    # Single move
    if !ctrlKey &&!shiftKey
      baseOffset = extentOffset
      extentOffset++

    # Moving with ctrl key
    if ctrlKey && !shiftKey
      remainingText = elementText.substring extentOffset
      nextSpace = remainingText.indexOf ' '
      if nextSpace == -1
        baseOffset = elementText.length - 1 # We have reached the end of the element text
        extentOffset = elementText.length
      else
        baseOffset = extentOffset + nextSpace + 1 # Jump to the next word
        extentOffset = baseOffset + 1

    # Single move with shift key
    if !ctrlKey && shiftKey
      extentOffset++
      if (baseOffset == extentOffset)
        extentOffset++

    # Moving with ctrl key and shift key
    if ctrlKey && shiftKey
      remainingText = elementText.substring extentOffset
      nextSpace = remainingText.indexOf ' '
      if nextSpace == -1
        extentOffset = elementText.length # We have reached the end of the element text
      else if nextSpace == 0
        @selectText @matchingElement, baseOffset, extentOffset + 1
        @handleRightArrowSelection shiftKey, ctrlKey
        return
      else
        if baseOffset < extentOffset + nextSpace
          extentOffset = extentOffset + nextSpace # Jump to the next word
        else
          extentOffset = extentOffset + nextSpace + 1

    @selectText @matchingElement, baseOffset, extentOffset

  handleLeftArrowSelection: (shiftKey, ctrlKey) ->
    baseOffset = @selectionBaseOffset
    extentOffset = @selectionExtentOffset
    reverseSelect = extentOffset > baseOffset
    elementText = @getElementText @matchingElement

    if extentOffset == 0
      return

    # Single move
    if !ctrlKey && !shiftKey
      if extentOffset > 1
        extentOffset--
        baseOffset = extentOffset - 1
      else
        baseOffset = 0
        extentOffset = 1

    # Moving with ctrl key
    if ctrlKey && !shiftKey
      remainingText = elementText.substring 0, extentOffset
      remainingText = remainingText.replace(/ +$/, '');
      previousSpace = remainingText.lastIndexOf ' '
      if previousSpace == -1
        baseOffset = 0 # We have reached the start of the element text
        extentOffset = baseOffset + 1
      else if previousSpace == extentOffset - 2
        @selectText @matchingElement, baseOffset, extentOffset - 1
        @handleLeftArrowSelection shiftKey, ctrlKey
        return
      else
        baseOffset = previousSpace + 1 # Move to the start of the previous word
        extentOffset = baseOffset + 1

    # Single move with shift key
    if !ctrlKey && shiftKey
      extentOffset--
      if (baseOffset == extentOffset)
        extentOffset--

    # Moving with ctrl key and shift key
    if ctrlKey && shiftKey
      remainingText = elementText.substring 0, extentOffset
      previousSpace = remainingText.lastIndexOf ' '
      if previousSpace == -1
        extentOffset = 0 # We have reached the start of the element text
      else if previousSpace == extentOffset - 1
        @selectText @matchingElement, baseOffset, extentOffset - 1
        @handleLeftArrowSelection shiftKey, ctrlKey
        return
      else
        if baseOffset < previousSpace
          extentOffset = previousSpace # Jump to the next word
        else
          extentOffset = previousSpace + 1

    @selectText @matchingElement, baseOffset, extentOffset


  getElementText: (element) ->
    element.localHintDescriptor.element.childNodes[0].nodeValue

  updateVisibleMarkers: (tabCount = 0) ->
    {hintKeystrokeQueue, linkTextKeystrokeQueue} = @markerMatcher
    TextHintCoordinator.sendMessage "updateKeyState", {hintKeystrokeQueue, linkTextKeystrokeQueue, tabCount}

  updateKeyState: ({hintKeystrokeQueue, linkTextKeystrokeQueue, tabCount}) ->
    extend @markerMatcher, {hintKeystrokeQueue, linkTextKeystrokeQueue}

    {linksMatched, userMightOverType} = @markerMatcher.getMatchingHints @hintMarkers, tabCount, this.getNextZIndex.bind this

    if linksMatched.length == 0
      @deactivateMode()
    else if linksMatched.length == 1
      @matchingElement = linksMatched[0]
      text = @getElementText @matchingElement
      length = text.indexOf ' '
      if length == -1
        length = text.length
      @selectText @matchingElement, 0, length
      @removeHintMarkers()
    else
      @hideMarker marker for marker in @hintMarkers
      @showMarker matched, @markerMatcher.hintKeystrokeQueue.length for matched in linksMatched

    @setIndicator()

  selectText: (linkMatched, startIndex, endIndex) ->
    @selectionBaseOffset = startIndex
    @selectionExtentOffset = endIndex

    if linkMatched.isLocalMarker
      localHintDescriptor = linkMatched.localHintDescriptor
      element = localHintDescriptor.element
      if startIndex < endIndex
        DomUtils.selectText element, startIndex, endIndex
      else
        DomUtils.selectText element, endIndex, startIndex

  #
  # Shows the marker, highlighting matchingCharCount characters.
  #
  showMarker: (linkMarker, matchingCharCount) ->
    return unless linkMarker.isLocalMarker
    linkMarker.style.display = ""
    for j in [0...linkMarker.childNodes.length]
      if (j < matchingCharCount)
        linkMarker.childNodes[j].classList.add("matchingCharacter")
      else
        linkMarker.childNodes[j].classList.remove("matchingCharacter")

  hideMarker: (linkMarker) -> linkMarker.style.display = "none" if linkMarker.isLocalMarker

  setIndicator: ->
    if windowIsFocused()
      typedCharacters = @markerMatcher.linkTextKeystrokeQueue?.join("") ? ""
      #indicator = @mode.indicator + (if typedCharacters then ": \"#{typedCharacters}\"" else "") + "."
      #@hintMode.setIndicator indicator

  deactivateMode: ->
    @removeHintMarkers()
    @hintMode?.exit()

  removeHintMarkers: ->
    DomUtils.removeElement @hintMarkerContainingDiv if @hintMarkerContainingDiv
    @hintMarkerContainingDiv = null

class AlphabetHints
  constructor: ->
    @linkHintCharacters = Settings.get "linkHintCharacters"
    # We use the keyChar from keydown if the link-hint characters are all "a-z0-9".  This is the default
    # settings value, and preserves the legacy behavior (which always used keydown) for users which are
    # familiar with that behavior.  Otherwise, we use keyChar from keypress, which admits non-Latin
    # characters. See #1722.
    @useKeydown = /^[a-z0-9]*$/.test @linkHintCharacters
    @hintKeystrokeQueue = []

  fillInMarkers: (hintMarkers) ->
    hintStrings = @hintStrings(hintMarkers.length)
    for marker, idx in hintMarkers
      marker.hintString = hintStrings[idx]
      marker.innerHTML = spanWrap(marker.hintString.toUpperCase()) if marker.isLocalMarker

  #
  # Returns a list of hint strings which will uniquely identify the given number of links. The hint strings
  # may be of different lengths.
  #
  hintStrings: (linkCount) ->
    hints = [""]
    offset = 0
    while hints.length - offset < linkCount or hints.length == 1
      hint = hints[offset++]
      hints.push ch + hint for ch in @linkHintCharacters
    hints = hints[offset...offset+linkCount]

    # Shuffle the hints so that they're scattered; hints starting with the same character and short hints are
    # spread evenly throughout the array.
    return hints.sort().map (str) -> str.reverse()

  getMatchingHints: (hintMarkers) ->
    matchString = @hintKeystrokeQueue.join ""
    linksMatched: hintMarkers.filter (linkMarker) -> linkMarker.hintString.startsWith matchString

  pushKeyChar: (keyChar, keydownKeyChar) ->
    @hintKeystrokeQueue.push (if @useKeydown then keydownKeyChar else keyChar)

  popKeyChar: -> @hintKeystrokeQueue.pop()

  # For alphabet hints, <Space> always rotates the hints, regardless of modifiers.
  shouldRotateHints: -> true

root = exports ? window
root.TextHints = TextHints