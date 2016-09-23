.. title: Test-Driven Development With Flask, PyTest, and SQLAlchemy
.. slug: test-driven-development-with-flask-pytest-and-sqlalchemy
.. date: 2016-09-22 21:58:56 UTC-04:00
.. tags: draft
.. category: 
.. link: 
.. description: 
.. type: text

First, we write our first test::

    from selenium import webdriver

    browser = webdriver.Firefox()
    browser.get('http://localhost:5000')

    assert 'Flask' in browser.body

If we try running it::
