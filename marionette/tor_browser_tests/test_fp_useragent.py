from marionette_driver import By
from marionette_driver.errors import MarionetteException

from marionette_harness import MarionetteTestCase

class Test(MarionetteTestCase):
    def test_useragent(self):
        with self.marionette.using_context('content'):
            self.marionette.navigate('about:robots')
            js = self.marionette.execute_script
            # Check that useragent string is as expected
            # We better know the ESR version we're testing
            self.assertEqual("Mozilla/5.0 (Windows NT 6.1; rv:52.0) Gecko/20100101 Firefox/52.0",
                              js("return navigator.userAgent"))
