(function () {
  'use strict';

  function setGuidanceOrigin(element, label, pending, sourceOrigin) {
    var originElement = document.getElementById(element.getAttribute('data-guidance-origin'));
    if (!originElement) return;
    var prefix = originElement.getAttribute('data-guidance-origin-prefix') || '';
    originElement.textContent = prefix + ' ' + label + (pending ? ' ' + pending : '') + '.';
    var reset = document.getElementById(element.getAttribute('data-guidance-inherit-button'));
    if (reset) reset.classList.toggle('hidden', sourceOrigin === 'provider_default');
  }

  function copyGuidanceInheritedDefault(button) {
    var fieldName = button.getAttribute('data-guidance-inherited-field');
    var value = button.getAttribute('data-guidance-inherited-value');
    var marker = document.getElementById(button.getAttribute('data-guidance-inherited-marker'));
    var dirtyMarker = document.getElementById(button.getAttribute('data-guidance-dirty-marker'));
    var input = document.getElementById(fieldName);
    if (!input) return;
    if (input.type === 'checkbox') {
      input.checked = value === '1';
    } else {
      input.value = value;
    }
    var slider = document.getElementById('mskslider.' + fieldName);
    if (slider) slider.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    if (marker) marker.value = '1';
    if (dirtyMarker) dirtyMarker.value = '0';
    setGuidanceOrigin(
      button,
      button.getAttribute('data-guidance-inherited-origin-label'),
      button.getAttribute('data-guidance-origin-pending'),
      button.getAttribute('data-guidance-inherited-origin')
    );
  }

  function bindGuidanceInheritedDefaultButtons(root) {
    root.querySelectorAll('[data-guidance-inherited-field]').forEach(function (button) {
      button.addEventListener('click', function (event) {
        event.preventDefault();
        copyGuidanceInheritedDefault(button);
      });
    });
  }

  function bindGuidanceInheritedMarkers(root) {
    if (root.__blissGuidanceInheritedMarkersBound) return;
    root.__blissGuidanceInheritedMarkersBound = true;
    var materialSliderMarkers = {};
    root.querySelectorAll('[data-guidance-inherited-field]').forEach(function (button) {
      var fieldName = button.getAttribute('data-guidance-inherited-field');
      var markerName = button.getAttribute('data-guidance-inherited-marker');
      var dirtyMarkerName = button.getAttribute('data-guidance-dirty-marker');
      var input = document.getElementById(fieldName);
      var marker = document.getElementById(markerName);
      var dirtyMarker = document.getElementById(dirtyMarkerName);
      if (!input || !marker || !dirtyMarker) return;
      var markHostOverride = function () {
        marker.value = '0';
        dirtyMarker.value = '1';
        setGuidanceOrigin(
          button,
          button.getAttribute('data-guidance-host-origin-label'),
          '',
          button.getAttribute('data-guidance-host-origin')
        );
      };
      materialSliderMarkers[fieldName] = markHostOverride;
      input.addEventListener('input', markHostOverride);
      input.addEventListener('change', markHostOverride);
    });
    // Material Skin creates its range sliders after this embedded page has
    // loaded, and copies values without notifying the numeric input. Delegate
    // events from later-created sliders so a drag is an explicit host override.
    var markMaterialSliderOverride = function (event) {
      var targetId = event.target && event.target.id ? event.target.id : '';
      var prefix = 'mskslider.';
      if (targetId.indexOf(prefix) !== 0) return;
      var marker = materialSliderMarkers[targetId.substring(prefix.length)];
      if (marker) marker();
    };
    root.addEventListener('input', markMaterialSliderOverride);
    root.addEventListener('change', markMaterialSliderOverride);
  }

  function updateGuidanceProviderControls(checkbox) {
    var controls = document.getElementById(checkbox.getAttribute('data-guidance-provider-controls'));
    if (!controls) return;
    var enabled = checkbox.checked;
    var usable = checkbox.getAttribute('data-guidance-provider-controls-usable') === '1';
    controls.classList.toggle('hidden', !enabled);
    controls.querySelectorAll('input, select, button').forEach(function (input) {
      input.disabled = !enabled || !usable;
    });
  }

  function bindGuidanceProviderControls(root) {
    root.querySelectorAll('[data-guidance-provider-controls]').forEach(function (checkbox) {
      checkbox.addEventListener('change', function () { updateGuidanceProviderControls(checkbox); });
      updateGuidanceProviderControls(checkbox);
    });
  }

  window.BlissGuidanceHostControls = {
    bindGuidanceInheritedDefaultButtons: bindGuidanceInheritedDefaultButtons,
    bindGuidanceInheritedMarkers: bindGuidanceInheritedMarkers,
    bindGuidanceProviderControls: bindGuidanceProviderControls
  };
}());
