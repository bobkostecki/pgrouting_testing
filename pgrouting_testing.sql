--database preparing
CREATE EXTENSION postgis;
CREATE EXTENSION pgrouting;

--import data from shapefile or osm
--changing srid
ALTER TABLE osm_roads
ALTER COLUMN geom 
TYPE Geometry(linestring, 2180) 
USING ST_Transform(geom, 2180);

--creating schema for separate data
CREATE SCHEMA route;

--creating car drivable net
CREATE TABLE route.roads AS 
WITH g AS 
(SELECT st_union(geom) AS geom FROM powiaty where jpt_nazwa_ in ('powiat Poznań', 'powiat poznański' ))
SELECT r.* AS geom FROM osm_roads r join g 
ON st_contains(g.geom, r.geom) where
fclass not in ('bridleway','footway', 'steps', 'path', 'busway', 'service','pedestrian', 'cycleway');
alter table route.roads add primary key (gid);

--adding columns for routing
ALTER TABLE route.roads 
ADD COLUMN source integer,
ADD COLUMN target integer,
ADD COLUMN cost_len double precision;
UPDATE route.roads SET cost_len = ST_Length(geom);

--topology creating
SELECT pgr_createTopology('route.roads', 0.01,'geom','gid');
SELECT pgr_analyzeGraph('route.roads', 0.01,'geom','gid');


--network correction
SELECT pgr_nodeNetwork('route.roads', 0.01, 'gid', 'geom');


ALTER TABLE route.roads_noded 
ADD COLUMN cost_len double precision,
ADD COLUMN rcost_len double precision;
add column cost_time double precision,
add column rcost_time double precision;
ADD COLUMN oneway character varying(1),
ADD COLUMN maxspeed smallint;


UPDATE route.roads_noded SET cost_len = ST_Length(geom);
UPDATE route.roads_noded SET rcost_len = ST_Length(geom);

SELECT pgr_createTopology('route.roads_noded', 0.01,'geom','id');
SELECT pgr_analyzeGraph('route.roads_noded', 0.01,'geom','id');


update route.roads_noded 
set oneway = r.oneway from route.roads r where old_id =gid;

ALTER TABLE route.roads_noded 
ADD COLUMN one_way integer;

update route.roads_noded 
set one_way = 0 --both directional
where oneway='B';

update route.roads_noded 
set one_way = 1 --one directional
where oneway='F';

update route.roads_noded 
set one_way = -1 --rev one directional
where oneway='T';

update route.roads_noded 
set maxspeed = r.maxspeed from route.roads r where old_id =gid;

select distinct maxspeed from route.roads_noded;

update route.roads_noded 
set maxspeed =40 where maxspeed=0;

update route.roads_noded 
set cost_time =cost_len/1000/maxspeed*60;

--adding columns for aStar
ALTER TABLE route.roads_noded
ADD COLUMN x1 double precision,
ADD COLUMN y1 double precision,
ADD COLUMN x2 double precision,
ADD COLUMN y2 double precision;

UPDATE route.roads_noded
SET x1 = st_x(st_startpoint(geom)),
    y1 = st_y(st_startpoint(geom)),
    x2 = st_x(st_endpoint(geom)),
    y2 = st_y(st_endpoint(geom));


--“F” means that only driving
--in direction of the linestring is allowed. “T” means
--that only driving against the direction of the
--linestring is allowed. “B” (default value) means that
--traffic is permitted in both directions.

--algorithms testing

--Dikstra shortest path 
SELECT seq, node, edge,cost,agg_cost,geom 
FROM pgr_dijkstra('SELECT id,
source::integer, target::integer,
cost_len::double precision AS cost
FROM route.roads_noded',12066,330, false)AS di
join route.roads_noded pt ON di.edge=pt.id;

--aStar shortest path 
SELECT * FROM pgr_aStar(
'SELECT id, source::INTEGER, target::bigint,
cost_len::double precision AS cost,x1,y1,x2,y2
FROM route.roads_noded',1852,2135,true
);

--Service Area analysis
with dd as (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target, cost_len::double precision as cost 
FROM route.roads_noded',446,3500)
)
SELECT ST_ConcaveHull(st_collect(geom),0.2) as geom FROM route.roads_noded net 
inner join dd on net.id=dd.edge;

--warapper function for driving distance with length - alphashape
CREATE OR REPLACE FUNCTION route.alphAShape(x double precision, y double precision, dim integer)
returns table (geom geometry) AS
$$
WITH dd AS (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target,cost_len::double precision AS cost
FROM route.roads_noded',
(SELECT id::integer FROM route.roads_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||x||' '||y||')',4326),2180) LIMIT 1),
dim, false)
)
SELECT  ST_ConcaveHull(st_collect(the_geom),0.2) AS geom
FROM route.roads_noded_vertices_pgr net
INNER JOIN dd ON net.id=dd.node;
$$
LANGUAGE 'sql';

SELECT x, route.alphaShape_len( 16.9,52.4,x)geom
FROM 
generate_series(1000,6000,1000)x ORDER BY x desc ;

--wrapper function for driving distance with time - alphashape
CREATE OR REPLACE FUNCTION route.alphaShape_time(x double precision, y double precision, dim integer)
returns table (geom geometry) AS
$$
WITH dd AS (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target,cost_time::double precision AS cost
FROM route.roads_noded',
(SELECT id::integer FROM route.roads_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||x||' '||y||')',4326),2180) LIMIT 1),
dim, false)
)
SELECT  ST_ConcaveHull(st_collect(the_geom),0.2) AS geom
FROM route.roads_noded_vertices_pgr net
INNER JOIN dd ON net.id=dd.node;
$$
LANGUAGE 'sql';


--generating multiple isochrones for one point
SELECT t, route.alphaShape_time( 16.9,52.4,t)geom
FROM 
generate_series(2,10,2)t ORDER BY t desc ;

--generating multiple iochrones for many points
with locations (id,x,y)as(
select id,x,y from
(values
 (1,16.8, 52.3),
 (2,17, 52.4),
 (3,16.9, 52.5)
)as locations (id,x,y)),
pol as (select t, route.alphaShape_time( x,y,t)geom
from locations, 
generate_series(3,15,3)t ORDER BY t desc)
select t, st_union(geom)geom 
from pol group by t order by t desc;



--Resolving TRSP Problem with restricion buffer
create or replace view route.restrictions as
with pol as (
select st_buffer(st_setsrid(st_point(359975,506557),2180),2000)as geom
)
select id as path, cost_len as cost
from route.roads_noded r inner join pol p 
on st_intersects(p.geom,r.geom)
SELECT * FROM pgr_trsp(
  $$ SELECT id, source, target, cost_len as cost, rcost_len as reverse_cost 
	FROM route.roads_noded$$,
  $$ select array[path] as path, cost from route.restrictions $$,
  24984, 47618,
  true)AS di
join route.roads_noded pt ON di.edge=pt.id;









