#!/usr/bin/env python3

import urllib.request
import bs4
import sys, time
import getopt

# copy cookie from browser
with open('goodreads.cookie', 'r') as f:
    cookie = f.read().strip()

def debugTag(tag, indent='\t'):
	lines = str(tag).splitlines()
	lines = ['\t' + line for line in lines]
	lines = '\n'.join(lines)
	# print('<!-- Bad Tag:\n' + lines + '\n-->')

def getPageData(typ, name, page):
	url = "https://www.goodreads.com/" + typ + "/show/" + name + "?page=" + str(page)
	print('<!-- loading ' + url + ' -->')
	req = urllib.request.Request(url)
	req.add_header("Cookie", cookie)
	page = urllib.request.urlopen(req).read()
	return bs4.BeautifulSoup(page, "lxml")

def getListRows(html):
	data = html.find_all('td')
	rows = {}

	for td in data:
		aTag = td.find('a', class_="bookTitle")
		if aTag is None:
			debugTag(td)
			continue
		title = aTag.text.strip()
		link = "https://www.goodreads.com" + aTag.attrs['href']

		rating = td.find('span', class_="minirating").text
		parts = rating.strip().split(' ')
		if len(parts) == 6:
			avg = float(parts[0])
			count = int(parts[4].replace(',', ''))
		else:
			avg = float(parts[-6])
			count = int(parts[-2].replace(',', ''))

		img = td.findParent().find('img', class_="bookCover")
		img = img.attrs['src']

		rows[title] = {'img': img, 'link': link, 'title': title, 'avg': avg, 'count': count}

	return rows

def getShelfRows(html):
	data = html.find_all('div', class_="elementList")
	rows = {}

	for div in data:
		aTag = div.find('a', class_="bookTitle")
		if aTag is None:
			debugTag(div)
			continue
		title = aTag.text.strip()
		link = "https://www.goodreads.com" + aTag.attrs['href']

		spans = div.find_all('span', class_="greyText")
		for sp in spans:
			if sp.text.find("rating") < 0:
				continue
			parts = sp.text.strip().split()
			avg = float(parts[2])
			count = int(parts[4].replace(',', ''))
			break

		img = div.find('img').attrs['src']

		rows[title] = {'img': img, 'link': link, 'title': title, 'avg': avg, 'count': count}

	return rows

def getAllPages(query, minAvg, minCount):
	listType = query[0]
	listName = query[1]
	pageCount = query[2]

	table = {}
	for i in range(pageCount):
		data = getPageData(listType, listName, i + 1)
		if listType == "list":
			rows = getListRows(data)
		else:
			rows = getShelfRows(data)
		print('<!-- Found ' + str(len(rows)) + ' rows -->')

		for k,v in rows.items():
			if v['avg'] >= minAvg and v['count'] >= minCount:
				table[k] = v
			else:
				print('<!-- removing book: ' + str(v) + ' -->')

		time.sleep(2)

	return table

def buildHtml(pages, minAvg, minCount):
	table = {}
	for page in pages:
		data = getAllPages(page, minAvg, minCount)
		table.update(data)

	table = list(table.values())
	table.sort(key=lambda x : -x['avg'])

	print('''<!DOCTYPE html>
	<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
	<head>
		<meta http-equiv="Content-Type" content="text/html;charset=utf-8">
		<title>Goodreads Books</title>
		<link rel="stylesheet" type="text/css" href="https://cdn.datatables.net/1.11.5/css/jquery.dataTables.css">
		<script type="text/javascript" charset="utf8" src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
		<script type="text/javascript" charset="utf8" src="https://cdn.datatables.net/1.11.5/js/jquery.dataTables.js"></script>
	</head>
	<body>

	<script>
	// Initialize DataTable on the table
	$(document).ready( function () {
		$('#sortableTable').DataTable();
	});
	</script>

	<table id="sortableTable">
	<thead>
	<tr><th>Image</th><th>Title</th><th>Average</th><th>Ratings</th></tr>
	</thead>
	''')

	for i in table:
		print('<tr><td><img src="{}" alt="{}"></td><td><a href="{}">{}</a></td><td>{}</td><td>{}</td></tr>'.format(i['img'], i['title'], i['link'], i['title'], i['avg'], i['count']))
	print('</table>')
	print('</body></html>')


try:
	opts, args = getopt.getopt(sys.argv[1:], "a:c:")
except getopt.GetoptError as err:
	print(err, file=sys.stderr)
	print("Usage: -a <minAvg> -c <minCount> <type:name:count>...")
	sys.exit(1)

optDict = dict(opts)
minAvg = float(optDict.get('-a', "3.8"))
minCount = int(optDict.get('-c', "500"))

pages = []
for arg in args:
	listType, listName, pageCount = arg.split(':')
	pageCount = int(pageCount)
	pages.append((listType, listName, pageCount))

buildHtml(pages, minAvg, minCount)
