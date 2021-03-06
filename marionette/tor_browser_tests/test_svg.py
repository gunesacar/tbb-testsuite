from marionette_driver import By
from marionette_driver.errors import MarionetteException, JavascriptException, NoSuchElementException

from marionette_harness import MarionetteTestCase

import testsuite


class Test(MarionetteTestCase):

    def setUp(self):
        MarionetteTestCase.setUp(self)

        ts = testsuite.TestSuite()
        self.ts = ts

        self.svg_dir = "file://%s/svg/" % ts.t['options']['test_data_dir']


    def test_svg(self):
        m = self.marionette
        svg_enabled = self.ts.t['test']['name'] == 'svg-enable'
        self.assertEqual(self.marionette.get_pref('svg.in-content.enabled'),
                svg_enabled,
                msg="svg.in-content.enabled is not set correctly")

        m.set_search_timeout(1000)

        with m.using_context('content'):

            # img src url
            m.navigate("%s/img_src_url.html" % self.svg_dir)
            svg_elt = m.find_element('id', 'svgImgElem')
            self.assertEqual(svg_elt.get_property('width'),
                    450 if svg_enabled else 24,
                    msg="img src url")

            # img data url
            m.navigate("%s/img_data_url.html" % self.svg_dir)
            svg_elt = m.find_element('id', 'svgImgElem')
            self.assertEqual(svg_elt.get_property('width'),
                    300 if svg_enabled else 24,
                    msg="img data url")

            # object data url
            m.navigate("%s/object_data_url.html" % self.svg_dir)
            try:
                visibility = m.execute_script('''
                                var elt = document.getElementById("svgObjectElem");
                                return elt.contentDocument.visibilityState;
                                ''')
            except JavascriptException:
                visibility = 'invisible'
            self.assertEqual(visibility,
                    'visible' if svg_enabled else 'invisible',
                    msg='object data url')

            # object remote url
            m.navigate("%s/object_remote_url.html" % self.svg_dir)
            try:
                visibility = m.execute_script('''
                                var elt = document.getElementById("svgObjectElem");
                                return elt.contentDocument.visibilityState;
                                ''')
            except JavascriptException:
                visibility = 'invisible'
            self.assertEqual(visibility,
                    'visible' if svg_enabled else 'invisible',
                    msg='object remote url')

            # inline svg
            m.navigate('%s/inline_svg.html' % self.svg_dir)
            try:
                elt_width = m.execute_script('''
                                var elt = document.getElementById("inlineSVG");
                                return elt.width.baseVal.value;
                                ''')
            except JavascriptException:
                elt_width = None
            print "width: %s" % elt_width
            self.assertEqual(elt_width,
                    300 if svg_enabled else None,
                    msg='inline svg')

            # iframe remote url
            m.navigate('%s/iframe_remote_url.html' % self.svg_dir)
            m.switch_to_frame(m.find_element('id', 'svgIframeElem'))
            found_elt = True
            try:
                svg_elt = m.find_element('tag name', 'svg')
            except NoSuchElementException:
                found_elt = False
            self.assertEqual(found_elt, True if svg_enabled else False,
                    msg="iframe remote url prompt")

