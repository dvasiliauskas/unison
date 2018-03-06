package org.unisonweb.util

import org.unisonweb.EasyTest._

object UtilTests {

  lazy val tests = scope("util") {
    suite(DequeTests.tests,
          SequenceTests.tests,
          BytesTests.tests,
          TextTests.tests,
          CritbyteTests.tests)
  }
}

object RunUtilTests extends App {
  run()(UtilTests.tests)
  // run(seed = 93276, prefix = "util.Critbyte.works like a map")(UtilTests.tests)
}

