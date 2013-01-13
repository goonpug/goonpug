#!/usr/bin/env python
# Copyright (C) 2013 Peter Rowlands
'''GoonPUG stats web app'''

from __future__ import division, absolute_import

from flask import Flask
app = Flask(__name__)


@app.route('/')
def hello_world():
    return 'Hello World!'


if __name__ == '__main__':
    app.run()
