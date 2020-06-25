SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

----------------------------------------------------------------------------------
-- Procedure Name: [dbo].[QDSCleanup]
--
-- Desc: This script clears entries from the QDS data to release space and avoid the automated space-based cleanup
--
--
-- Parameters:
--	INPUT
--		@DatabaseName	SYSNAME	-- Name of the database to apply the QDS cleanup process on
--
--		@CleanAdhocStale BIT	-- Flag to clean queries that:
--									Are ad-hoc queries (don't belong to any object)
--									Haven't been executed at least @MinExecutionCount times
--									Haven't been executed in the last @Retention hours
--								(Default: 0; is it included in the @CleanStale flag)
--		@CleanStale BIT			-- Flag to clean queries that:
--									Queries belonging to an object and ad-hoc ones (don't belong to any object)
--									Haven't been executed at least @MinExecutionCount times
--									Haven't been executed in the last @Retention hours
--								(Default: 1)
--		@Retention INT			-- Hours since the last execution of the query (Default: 168 (24*7), one week)
--		@MinExecutionCount INT	-- Minimum number of executions NOT to delete the query Default :2; deletes queries executed only once)
--		@CleanOrphan BIT		-- Flag to clean queries associated with deleted objects. (Default: 1)
--		@CleanInternal BIT		-- Flag to clean queries identified as internal ones by QDS (UPDATE STATISTICS, INDEX REBUILD....). (Default: 1)
--
--		@ReportAsText BIT		--	Flag to print out a report on the space released after the removal of the queries' information (in a text format). (Default: 0)
--		@ReportAsTable BIT		--	Flag to print out a report on the space released after the removal of the queries' information (in a table format). (Default: 0)
--		@ReportOutputTable NVARCHAR(800)	-- Name of the destination table to export the report
--									Format of the destination table:
--									CREATE TABLE [dbo].[QDSCleanSummary]
--									(
--										[ExecutionTime]		DATETIMEOFFSET(7)	NOT	NULL,
--										[ServerName]		SYSNAME				NOT	NULL,
--										[DatabaseName]		SYSNAME				NOT	NULL,
--										[QueryType]			NVARCHAR(16)		NOT	NULL,
--										[QueryCount]		BIGINT					NULL,
--										[PlanCount]			BIGINT					NULL,	
--										[QueryTextKBs]		BIGINT					NULL,
--										[PlanXMLKBs]		BIGINT					NULL,
--										[RunStatsKBs]		BIGINT					NULL,
--										[WaitStatsKBs]		BIGINT					NULL,
--										[CleanupParameters]		XML						NULL
--									)
--									The insertion uses named columns, so extra columns will not be populated but won't cause failures
--
--		@QueryDetailsAsTable BIT	--	Flag to print out a report with the details of each query targeted for deletion, including the query text and the parameters used to select the query
--		@QueryDetailsOutputTable NVARCHAR(800)	-- Name of the destination table to export the query details' report
--									Format of the destination table:
--									CREATE TABLE [db].[CleanQueryDetails]
--									(
--										[ExecutionTime]		DATETIMEOFFSET(7)	NOT	NULL,
--										[ServerName]		SYSNAME				NOT	NULL,
--										[DatabaseName]		SYSNAME				NOT	NULL,
--										[QueryType]			NVARCHAR(16)		NOT NULL,
--										[ObjectName]		NVARCHAR(260)			NULL,
--										[QueryId]			BIGINT				NOT NULL,
--										[LastExecutionTime] DATETIMEOFFSET(7)		NULL,
--										[ExecutionCount]	BIGINT					NULL,
--										[QueryText]			VARBINARY(MAX)			NULL,
--										[CleanupParameters]		XML						NULL
--									)
--								In order to decompress the content og the [QueryText] column, use the command 
--									CAST(DECOMPRESS([QueryText] AS NVARCHAR(MAX))
--								The column Parameters contains the complete list of parameters. Since this list is prone to changes
--
--		@Test BIT				-- Flag to execute the SP in test mode. (Default: 0: queries are deleted)
--		@Verbose BIT			-- Flag to include verbose messages. (Default: 0; no output messages)
--
--
-- Sample execution:
--
--		*** Report-Only: this execution is recommended before applying any change into a live environment in order to review the impact of the different parameters would have
--
--		EXECUTE [dbo].[QDSCleanup]
--			 @DatabaseName = 'Database01'
--			,@CleanAdhocStale = 0
--			,@CleanStale = 1
--			,@Retention = 24
--			,@MinExecutionCount = 2
--			,@CleanOrphan = 1
--			,@CleanInternal = 1
--			,@ReportAsTable = 1
--			,@QueryDetailsAsTable = 1
--			,@Test = 1
--
--		This execution will generate 2 separate reports:
--			Estimated space used by the queries to be deleted (including query text, execution plans, and both runtime and wait statistics
--			Complete list of the queries selected to be deleted, along with details on their execution to analyze why they have been selected to be deleted and the text of the query itself
--		Using the following parameters:
--			Queries that haven't been executed at (@MinExecutionCount) 2 times in the past (@Retention) 24 hours
--			Queries associated to objects that no longer exist (@Orphan = 1)
--			Internal queries such as index / statistics maintenance
--		But won't perform any actual cleanup
--
--
--
--		*** Basic-logged cleanup: this execution is recommended when a cleanup is required but logging is necessary for further analysis afterwards
--
--		EXECUTE [dbo].[QDSCleanup]
--			 @DatabaseName = 'Database01'
--			,@ReportOutputTable = '[LinkedSQL].[CentralMaintenanceDB].[dbo].[QDSCleanSummary]'
--			,@QueryDetailsOutputTable = '[MaintenanceDB].[dbo].[QDSCleanQueryDetails]'
--
--		This execution will generate 2 separate reports:
--			Stored in the table [dbo].[QDSCleanSummary] on the database [CentralMaintenanceDB] on the linked server [LinkedSQL] : Estimated space used by the queries to be deleted (including query text, execution plans, and both runtime and wait statistics
--			Stored in the table [dbo].[QDSCleanQueryDetails] on the local database [MaintenanceDB]: Complete list of the queries selected to be deleted, along with details on their execution to analyze why they have been selected to be deleted and the text of the query itself
--		using the default parameters
--		Will also perform the actual cleanup usin the default parameters
--
--
-- Date: 2020.06.XX
-- Auth: Pablo Lozano (@sqlozano)
--
----------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE [dbo].[QDSCleanup]
(
	@DatabaseName SYSNAME = NULL,
	@CleanAdhocStale BIT = 0,
	@CleanStale BIT = 1,
	@Retention INT = 168,
	@MinExecutionCount INT = 2,
	@CleanOrphan BIT = 1,
	@CleanInternal BIT = 1,
	@ReportAsText BIT = 0,
	@ReportAsTable BIT = 0,
	@ReportOutputTable NVARCHAR(800) = NULL,
	@QueryDetailsAsTable BIT = 0,
	@QueryDetailsOutputTable NVARCHAR(800) = NULL,
	@Test BIT = 0,
	@Verbose BIT = 0,
	@Debug BIT = 0
)
AS
BEGIN
SET NOCOUNT ON

-- Check whether @DatabaseName actually exists - START
IF NOT EXISTS (SELECT 1 FROM [sys].[databases] WHERE [name] = @DatabaseName)
BEGIN
	RAISERROR('The database [%s] does not exist', 16, 0, @DatabaseName)
	RETURN
END
-- Check whether @DatabaseName actually exists - START

-- Check whether @DatabaseName is ONLINE - START
IF EXISTS (SELECT 1 FROM [sys].[databases] WHERE [name] = @DatabaseName AND [state_desc] <> 'ONLINE')
BEGIN
	RAISERROR('The database [%s] is not online', 16, 0, @DatabaseName)
	RETURN
END
-- Check whether @DatabaseName is ONLINE - END

DECLARE @SqlCmd NVARCHAR(MAX) = ''
DECLARE @ExecutionTime DATETIMEOFFSET(7) = GETUTCDATE()

-- Declare variable & Create table to extract @@ROWCOUNT values from dynamic T-SQL - START
DECLARE @Rows BIGINT 
CREATE TABLE #Rows ( r BIGINT )
-- Declare variable & Create table to extract @@ROWCOUNT values from dynamic T-SQL - END

-- Count total # of queries in @DatabaseName's QDS - START
IF (@Verbose = 1)
BEGIN
	DECLARE @TotalQueriesCount BIGINT
	SET @SqlCmd = 'INSERT INTO #Rows SELECT COUNT(1) FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query]'
	IF (@Debug = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)
	SELECT TOP(1) @TotalQueriesCount = i FROM #Rows

	TRUNCATE TABLE #Rows

	PRINT 'Total queries: ' + CAST(@TotalQueriesCount AS VARCHAR(20))
END
-- Count total # of queries in @DatabaseName's QDS - END


-- Create table #DeleteableQueryTable to store the list of queries and plans (when forced on a query) to be deleted - START
DROP TABLE IF EXISTS #DeleteableQueryTable
CREATE TABLE #DeleteableQueryTable
(
	[QueryType] NVARCHAR(16),
	[query_id] BIGINT,
	[plan_id] BIGINT,
	[ForcedPlan] BIT
)
-- Create table #DeleteableQueryTable to store the list of queries and plans (when forced on a query) to be deleted - END


-- Load ad-hoc stale queries into #DeleteableQueryTable - START
 -- When a full cleanup of all stale queries is selected, this is ignored to avoid scaning the QDS tables twice
IF (@CleanAdhocStale = 1) AND (@CleanStale = 0)
BEGIN
	SET @SqlCmd = 'INSERT INTO #DeleteableQueryTable
	SELECT ''AdhocStale'', [qsq].[query_id], [qsp].[plan_id], [qsp].[is_forced_plan] 
	FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] AS [qsq]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_plan] AS [qsp]
		ON [qsp].[query_id] = [qsq].[query_id]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_runtime_stats] AS [qsrs]
		ON [qsrs].[plan_id] = [qsp].[plan_id]
	WHERE [qsq].[object_id] = 0
	GROUP BY [qsq].[query_id], [qsp].[plan_id], [qsp].[is_forced_plan] 
	HAVING SUM([qsrs].[count_executions]) < ' + CAST(@MinExecutionCount AS NVARCHAR(16)) + '
	AND MAX([qsq].[last_execution_time]) < DATEADD (HOUR, - ' + CAST(@Retention AS NVARCHAR(16)) + ', GETUTCDATE())
	INSERT INTO #Rows (r) VALUES (@@ROWCOUNT)'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)

	SELECT TOP(1) @Rows = r FROM #Rows
	TRUNCATE TABLE #Rows

	IF (@Verbose = 1)
	BEGIN
		PRINT 'Adhoc stale queries criteria: executed less than ' + CAST(@MinExecutionCount AS VARCHAR(8)) + ' times, and not executed for the last '+ CAST (@Retention AS VARCHAR(8)) +' hours'
		PRINT 'Adhoc stale queries found: ' + CAST(@Rows AS VARCHAR(20))
	END
END
-- Load ad-hoc stale queries into #DeleteableQueryTable - END

-- Load stale queries into #StaleQueryTable - START
IF (@CleanStale = 1)
BEGIN
	SET @SqlCmd = 'INSERT INTO #DeleteableQueryTable
	SELECT 
		''Stale''
		,[qsq].[query_id]
		,[qsp].[plan_id]
		,[qsp].[is_forced_plan]
	FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] AS [qsq]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_plan] AS [qsp]   
		ON [qsp].[query_id] = [qsq].[query_id]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_runtime_stats] AS [qsrs]
		ON [qsrs].[plan_id] = [qsp].[plan_id]
	GROUP BY [qsq].[query_id], [qsp].[plan_id], [qsp].[is_forced_plan]
	HAVING SUM([qsrs].[count_executions]) < ' + CAST(@MinExecutionCount AS NVARCHAR(16)) + '
	AND MAX([qsq].[last_execution_time]) < DATEADD (HOUR, - ' + CAST(@Retention AS NVARCHAR(16)) + ', GETUTCDATE())
	INSERT INTO #Rows (r) VALUES (@@ROWCOUNT)'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)

	SELECT TOP(1) @Rows = r FROM #Rows
	TRUNCATE TABLE #Rows
	
	IF (@Verbose = 1)
	BEGIN
		PRINT 'Stale queries: ' + CAST(@Rows AS VARCHAR(19)) + ' (executed less than ' + CAST(@MinExecutionCount AS VARCHAR(8)) + ' times, and not executed for the last '+ CAST (@Retention AS VARCHAR(8)) +' hours)'
		PRINT 'Stale queries found: ' + CAST(@Rows as VARCHAR(20))
	END
END
-- Load stale queries into #StaleQueryTable - END


-- Load internal queries into #InternalQueryTable - START 
IF (@CleanInternal = 1)
BEGIN
	SET @SqlCmd = 'INSERT INTO #DeleteableQueryTable
	SELECT 
		''Internal''
		,[qsq].[query_id]
		,[qsp].[plan_id]
		,[qsp].[is_forced_plan]
	FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] AS [qsq]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_plan] AS [qsp]
	ON [qsq].[query_id] = [qsp].[query_id]
	WHERE [qsq].[is_internal_query] = 1

	INSERT INTO #Rows (r) VALUES (@@ROWCOUNT)'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)

	SELECT TOP(1) @Rows = r FROM #Rows
	TRUNCATE TABLE #Rows

	IF (@Verbose = 1)
	BEGIN
		PRINT 'Internal queries found: ' + CAST(@Rows AS VARCHAR(19))
	END
END
-- Load internal queries into #InternalQueryTable - END


-- Load orphan queries into #DeleteableQueryTable - START
IF (@CleanOrphan = 1)
BEGIN
	SET @SqlCmd = 'INSERT INTO #DeleteableQueryTable
	SELECT 
		''Orphan''
		,[qsq].[query_id]
		,[qsp].[plan_id]
		,[qsp].[is_forced_plan]
	FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] AS [qsq]
	JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_plan] AS [qsp]
		ON [qsp].[query_id] = [qsq].[query_id]
	WHERE [qsq].[object_id] <> 0 
		AND [qsq].[object_id] NOT IN (SELECT [object_id] FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[objects])

	INSERT INTO #Rows (r) VALUES (@@ROWCOUNT)'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)

	SELECT TOP(1) @Rows = r FROM #Rows
	TRUNCATE TABLE #Rows

	IF (@Verbose = 1)
	BEGIN
		PRINT 'Orphan queries found: ' + CAST(@Rows AS VARCHAR(19))
	END
END
-- Load orphan queries into #DeleteableQueryTable - END

-- Create indexes to order the queries and plans to be deleted to reduce the effort when querying #DeleteableQueryTable - START
CREATE CLUSTERED INDEX [CIX_DeleteableQueryTable_QueryID] ON #DeleteableQueryTable (query_id)
CREATE NONCLUSTERED INDEX [NCIX_DeleteableQueryTable_PlanID] ON #DeleteableQueryTable (plan_id)
-- Create indexes to order the queries and plans to be deleted to reduce the effort when querying #DeleteableQueryTable - END


-- Summary Report: Prepare user-friendly output (as table or text) - START
IF ( (@ReportAsTable = 1) OR (@ReportAsText = 1)  OR (@ReportOutputTable IS NOT NULL) )
BEGIN

	-- Summary Report: Create table #Report to store metrics before outputing them - START
	DROP TABLE IF EXISTS #Report
	CREATE TABLE #Report
	(
		[QueryType]		NVARCHAR(16)		,
		[QueryCount]	BIGINT		NULL	,
		[PlanCount]		BIGINT		NULL	,
		[QueryTextKBs]	BIGINT		NULL	,
		[PlanXMLKBs]	BIGINT		NULL	,
		[RunStatsKBs]	BIGINT		NULL	,
		[WaitStatsKBs]	BIGINT		NULL 
	)
	-- Summary Report: Create table #Report to store metrics before outputing them - END
	
	-- Summary Report: Use @SqlCmd to load details into #Report - START
	SET @SqlCmd = 'INSERT INTO #Report
		SELECT 
			[QueryType]			=	[dqt].[QueryType]
			,[QueryCount]		=	COUNT(DISTINCT [dqt].[query_id])
			,[PlanCount]		=	COUNT(DISTINCT [dqt].[plan_id])
			,[QueryTextKBs]		=	SUM(DATALENGTH([qsqt].[query_sql_text])) / 1024
			,[PlanXMLKBs]		=	SUM(DATALENGTH([qsp].[query_plan])) / 1024
			,[RunStatsKBs]		=	( COUNT([qsrs].[runtime_stats_id]) * 653 ) / 1024
			,[WaitStatsKBs]		=	( COUNT([qsws].[wait_stats_id]) * 315 ) / 1024
		FROM #DeleteableQueryTable [dqt]
			INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] [qsq]
				ON [dqt].[query_id] = [qsq].[query_id]
			INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_plan] [qsp]
				ON [dqt].[plan_id] = [qsp].[plan_id]
			LEFT JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query_text] [qsqt]
				ON [qsq].[query_text_id] = [qsqt].[query_text_id]
			LEFT JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_runtime_stats] [qsrs]
				ON [dqt].[plan_id] = [qsrs].[plan_id]
			LEFT JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_wait_stats] [qsws]
				ON [qsws].[plan_id] = [dqt].[plan_id]
		GROUP BY [dqt].[QueryType]'	
	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)
	-- Summary Report: Use @SqlCmd to load details into #Report - END
END
-- Summary Report: Prepare user-friendly output (as table or text) - END


-- Summary Report: Generate report as a Table - START
IF (@ReportAsTable = 1)
BEGIN
	SELECT 
		 @ExecutionTime AS [ExecutionTime]
		,@@SERVERNAME AS [ServerName]
		,DB_NAME() AS [DatabaseName]
		,[QueryType]		
		,[QueryCount]	
		,[PlanCount]		
		,[QueryTextKBs]
		,[PlanXMLKBs]
		,[RunStatsKBs]
		,[WaitStatsKBs]
	FROM #Report
END
-- Summary Report: Generate report as a Table - END

-- Summary Report: Generate report as text - START
IF (@ReportAsText = 1)
BEGIN

	DECLARE @QueryCount		BIGINT
	DECLARE @PlanCount		BIGINT
	DECLARE @QueryTextKBs	BIGINT
	DECLARE @PlanXMLKBs		BIGINT
	DECLARE @RunStatsKBs	BIGINT
	DECLARE @WaitStatsKBs	BIGINT

	-- Summary Report: Adhoc Stale query details - START
	IF EXISTS (SELECT 1 FROM #Report WHERE [QueryType] = 'AdhocStale')
	BEGIN
		SELECT
			@QueryCount		=	[QueryCount]
			,@PlanCount		=	[PlanCount]
			,@QueryTextKBs	=	[QueryTextKBs]
			,@PlanXMLKBs	=	[PlanXMLKBs]
			,@RunStatsKBs	=	[RunStatsKBs]
			,@WaitStatsKBs	=	[WaitStatsKBs]
		FROM #Report 
		WHERE [QueryType] = 'AdhocStale'

		PRINT ''
		PRINT '**********************************'
		PRINT '*   Adhoc Stale queries found    *'
		PRINT '**********************************'
		PRINT '# of Queries : '				+ CAST(@QueryCount		AS VARCHAR(20))
		PRINT '# of Plans : '				+ CAST(@PlanCount		AS VARCHAR(20))
		PRINT 'KBs of query texts : '		+ CAST(@QueryTextKBs	AS VARCHAR(20))
		PRINT 'KBs of execution plans : '	+ CAST(@PlanXMLKBs		AS VARCHAR(20))
		PRINT 'KBs of runtime stats : '		+ CAST(@RunStatsKBs		AS VARCHAR(20))
		PRINT 'KBs of wait stats : '		+ CAST(@WaitStatsKBs	AS VARCHAR(20))
		PRINT ''
	END
	-- Summary Report: Adhoc Stale query details - END

	-- Summary Report: Stale query details - START
	IF EXISTS (SELECT 1 FROM #Report WHERE [QueryType] = 'Stale')
	BEGIN
		SELECT
			@QueryCount		=	[QueryCount]
			,@PlanCount		=	[PlanCount]
			,@QueryTextKBs	=	[QueryTextKBs]
			,@PlanXMLKBs	=	[PlanXMLKBs]
			,@RunStatsKBs	=	[RunStatsKBs]
			,@WaitStatsKBs	=	[WaitStatsKBs]
		FROM #Report 
		WHERE [QueryType] = 'Stale'

		PRINT ''
		PRINT '**********************************'
		PRINT '*       Stale queries found      *'
		PRINT '**********************************'
		PRINT '# of Queries : '				+ CAST(@QueryCount		AS VARCHAR(20))
		PRINT '# of Plans : '				+ CAST(@PlanCount		AS VARCHAR(20))
		PRINT 'KBs of query texts : '		+ CAST(@QueryTextKBs	AS VARCHAR(20))
		PRINT 'KBs of execution plans : '	+ CAST(@PlanXMLKBs		AS VARCHAR(20))
		PRINT 'KBs of runtime stats : '		+ CAST(@RunStatsKBs		AS VARCHAR(20))
		PRINT 'KBs of wait stats : '		+ CAST(@WaitStatsKBs	AS VARCHAR(20))
		PRINT ''
	END
	-- Summary Report: Stale query details - END

	-- Summary Report: Internal query details - START
	IF EXISTS (SELECT 1 FROM #Report WHERE [QueryType] = 'Internal')
	BEGIN
		SELECT
			@QueryCount		=	[QueryCount]
			,@PlanCount		=	[PlanCount]
			,@QueryTextKBs	=	[QueryTextKBs]
			,@PlanXMLKBs	=	[PlanXMLKBs]
			,@RunStatsKBs	=	[RunStatsKBs]
			,@WaitStatsKBs	=	[WaitStatsKBs]
		FROM #Report 
		WHERE [QueryType] = 'Internal'

		PRINT ''
		PRINT '**********************************'
		PRINT '*     Internal queries found     *'
		PRINT '**********************************'
		PRINT '# of Queries : '				+ CAST(@QueryCount		AS VARCHAR(20))
		PRINT '# of Plans : '				+ CAST(@PlanCount		AS VARCHAR(20))
		PRINT 'KBs of query texts : '		+ CAST(@QueryTextKBs	AS VARCHAR(20))
		PRINT 'KBs of execution plans : '	+ CAST(@PlanXMLKBs		AS VARCHAR(20))
		PRINT 'KBs of runtime stats : '		+ CAST(@RunStatsKBs		AS VARCHAR(20))
		PRINT 'KBs of wait stats : '		+ CAST(@WaitStatsKBs	AS VARCHAR(20))
		PRINT ''
	END
	-- Summary Report: Internal query details - END

	-- Summary Report: Orphan query details - START
	IF EXISTS (SELECT 1 FROM #Report WHERE [QueryType] = 'Orphan')
	BEGIN
		SELECT
			@QueryCount		=	[QueryCount]
			,@PlanCount		=	[PlanCount]
			,@QueryTextKBs	=	[QueryTextKBs]
			,@PlanXMLKBs	=	[PlanXMLKBs]
			,@RunStatsKBs	=	[RunStatsKBs]
			,@WaitStatsKBs	=	[WaitStatsKBs]
		FROM #Report 
		WHERE [QueryType] = 'Orphan'

		PRINT ''
		PRINT '**********************************'
		PRINT '*      Orphan queries found      *'
		PRINT '**********************************'
		PRINT '# of Queries : '				+ CAST(@QueryCount		AS VARCHAR(20))
		PRINT '# of Plans : '				+ CAST(@PlanCount		AS VARCHAR(20))
		PRINT 'KBs of query texts : '		+ CAST(@QueryTextKBs	AS VARCHAR(20))
		PRINT 'KBs of execution plans : '	+ CAST(@PlanXMLKBs		AS VARCHAR(20))
		PRINT 'KBs of runtime stats : '		+ CAST(@RunStatsKBs		AS VARCHAR(20))
		PRINT 'KBs of wait stats : '		+ CAST(@WaitStatsKBs	AS VARCHAR(20))
		PRINT ''
	END
	-- Summary Report: Orphan query details - END
END
-- Summary Report: Generate report as text - END


-- Summary Report: Persisted-table output - START
IF (@ReportOutputTable IS NOT NULL)
BEGIN
	DECLARE @ReportOutputInsert NVARCHAR(MAX)
	SET @ReportOutputInsert = '
	INSERT INTO ' + @ReportOutputTable + ' (
		[ExecutionTime] 
		,[ServerName]	
		,[DatabaseName]	
		,[QueryType]		
		,[QueryCount]	
		,[PlanCount]		
		,[QueryTextKBs]	
		,[PlanXMLKBs]	
		,[RunStatsKBs]	
		,[WaitStatsKBs]
		,[CleanupParameters]
	)
	SELECT 
		'''+CAST(@ExecutionTime AS NVARCHAR(34))+'''
		,'''+@@SERVERNAME+'''
		,'''+DB_NAME()+'''
		,[QueryType]		
		,[QueryCount]	
		,[PlanCount]		
		,[QueryTextKBs]
		,[PlanXMLKBs]
		,[RunStatsKBs]
		,[WaitStatsKBs]
		,(	SELECT 
				'+CAST(@CleanAdhocStale AS NVARCHAR(8))+' AS [CleanAdhocStale],
				'+CAST(@CleanStale AS NVARCHAR(8))+' AS [CleanStale],
				'+CAST(@Retention AS NVARCHAR(8))+' AS [Retention],
				'+CAST(@MinExecutionCount AS NVARCHAR(8))+' AS [MinExecutionCount],
				'+CAST(@CleanOrphan AS NVARCHAR(8))+' AS [CleanOrphan],
				'+CAST(@CleanInternal AS NVARCHAR(8))+' AS [CleanInternal]
			FOR XML PATH (''CleanupParameters''), ROOT(''Root'')
		) as [CleanupParameters]
	FROM #Report
	ORDER BY [QueryType] ASC'
	IF (@Debug = 1) PRINT (@ReportOutputInsert)
	EXECUTE (@ReportOutputInsert)
END
-- Summary Report: Persisted-table output - END


-- Detailed Report: Prepare user-friendly output (as table or text) - START
IF ( ( @QueryDetailsAsTable = 1 ) OR ( @QueryDetailsOutputTable IS NOT NULL) )
BEGIN
	-- Detailed Report: Create table #Report to store metrics before outputing them - START
	DROP TABLE IF EXISTS #QueryDetailsStagingTable
	CREATE TABLE #QueryDetailsStagingTable
	(
			[QueryType] NVARCHAR(16) NOT NULL,
			[QueryId] BIGINT NOT NULL,
			[ObjectID] INT NOT NULL,
			[LastExecutionTime] DATETIMEOFFSET(7) NULL,
			[ExecutionCount] BIGINT NULL,
			[QueryText] VARBINARY(MAX) NULL
	)
	-- Detailed Report: Create table #Report to store metrics before outputing them - END

	-- Detailed Report: Use @SqlCmd to load details into #QueryDetailsStagingTable - START
	SET @SqlCmd = 'INSERT INTO #QueryDetailsStagingTable
	SELECT
		[dqt].[QueryType]
		,[dqt].[query_id]
		,[qsq].[object_id]
		,[qsq].[last_execution_time]
		,SUM([qsrs].[count_executions])
		,COMPRESS([qsqt].[query_sql_text])
	FROM #DeleteableQueryTable [dqt]
		INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query] [qsq]
			ON [dqt].[query_id] = [qsq].[query_id]
		INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_query_text] [qsqt]
			ON [qsq].[query_text_id] = [qsqt].[query_text_id]
		INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[query_store_runtime_stats] [qsrs]
			ON [dqt].[plan_id] = [qsrs].[plan_id]
	GROUP BY [dqt].[QueryType], [dqt].[query_id], [qsq].[object_id], [qsq].[last_execution_time], [qsqt].[query_sql_text]'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)
	-- Detailed Report: Use @SqlCmd to load details into #QueryDetailsStagingTable - END


	-- Detailed Report: Create an index on #QueryDetailsStagingTable to prevent scans - START
	CREATE CLUSTERED INDEX [CIX_QueryDetailsStagingTable_QueryID] ON #QueryDetailsStagingTable (QueryID)
	-- Detailed Report: Create an index on #QueryDetailsStagingTable to prevent scans - END


	-- Detailed Report: Create table #QueryDetailsTable to store query details before processing them - START
	DROP TABLE IF EXISTS #QueryDetailsTable
	CREATE TABLE #QueryDetailsTable
	(
			[QueryType] NVARCHAR(16) NOT NULL,
			[ObjectName] NVARCHAR(270) NOT NULL,
			[QueryId] BIGINT NOT NULL,
			[LastExecutionTime] DATETIMEOFFSET(7) NULL,
			[ExecutionCount] BIGINT NULL,
			[QueryText] VARBINARY(MAX) NULL
	)
	-- Detailed Report: Create table #QueryDetailsTable to store query details before processing them - END

	-- Detailed Report: Load details of queries including adhoc and orphan queries - START
	SET @SqlCmd = 'INSERT INTO #QueryDetailsTable
			SELECT
			[qdst].[QueryType]
			,QUOTENAME([s].[name]) + ''.'' + QUOTENAME([o].[name])
			,[qdst].[QueryID]
			,[qdst].[LastExecutionTime]
			,[qdst].[ExecutionCount]
			,[qdst].[QueryText]
		FROM #QueryDetailsStagingTable [qdst]
		INNER JOIN ' + QUOTENAME(@DatabaseName) + '.[sys].[objects] [o]
			ON [qdst].[ObjectId] = [o].[object_id]
		INNER JOIN [sys].[schemas] [s]
			ON [o].[schema_id] = [s].[schema_id]

		UNION ALL

		SELECT
			[qdst].[QueryType]
			,''*** adhoc query ***''
			,[qdst].[QueryID]
			,[qdst].[LastExecutionTime]
			,[qdst].[ExecutionCount]
			,[qdst].[QueryText]
		FROM #QueryDetailsStagingTable [qdst]
		WHERE [qdst].[ObjectId] = 0

		UNION ALL

		SELECT
			[qdst].[QueryType]
			,''*** deleted object ***''
			,[qdst].[QueryID]
			,[qdst].[LastExecutionTime]
			,[qdst].[ExecutionCount]
			,[qdst].[QueryText]
		FROM #QueryDetailsStagingTable [qdst]
		WHERE [qdst].[ObjectId]  <> 0 
			AND [qdst].[ObjectId] NOT IN (SELECT [object_id] FROM ' + QUOTENAME(@DatabaseName) + '.[sys].[objects])'

	IF (@Verbose = 1) PRINT (@SqlCmd)
	EXECUTE (@SqlCmd)
	-- Detailed Report: Load details of queries including adhoc and orphan queries - END


	-- Detailed Report: Generate user-friendly output as table - START
	IF ( @QueryDetailsAsTable = 1 )
	BEGIN
		SELECT 
			@ExecutionTime AS [ExecutionTime]
			,@@SERVERNAME AS [ServerName]
			,DB_NAME() AS [DatabaseName]
			,[qdt].[QueryType]
			,[qdt].[ObjectName]
			,[qdt].[QueryId]
			,[qdt].[LastExecutionTime]
			,[qdt].[ExecutionCount]
			,CAST(DECOMPRESS([qdt].[QueryText]) AS NVARCHAR(MAX)) AS [QueryText]
		FROM #QueryDetailsTable [qdt]
		ORDER BY [qdt].[QueryType], [qdt].[ObjectName], [qdt].[QueryID]
	END
	-- Detailed Report: Generate user-friendly output as table - END


	-- Detailed Report: Persisted-table output - START
	IF (@QueryDetailsOutputTable IS NOT NULL)
	BEGIN
		DECLARE @QueryDetailsOutputInsert NVARCHAR(MAX)
		SET @QueryDetailsOutputInsert = '
		INSERT INTO ' + @QueryDetailsOutputTable + ' (
			[ExecutionTime] 
			,[ServerName]	
			,[DatabaseName]	
			,[QueryType]
			,[ObjectName]
			,[QueryID]	
			,[LastExecutionTime]	
			,[ExecutionCount]
			,[QueryText]
			,[CleanupParameters]
		)
		SELECT
			'''+CAST(@ExecutionTime AS NVARCHAR(34))+'''
			,'''+@@SERVERNAME+'''
			,'''+DB_NAME()+'''
			,[qdt].*
			,(	SELECT 
					' + CAST(@CleanAdhocStale AS NVARCHAR(8))	+ ' AS [CleanAdhocStale],
					' + CAST(@CleanStale AS NVARCHAR(8))		+ ' AS [CleanStale],
					' + CAST(@Retention AS NVARCHAR(8))			+ ' AS [Retention],
					' + CAST(@MinExecutionCount AS NVARCHAR(8))	+ ' AS [MinExecutionCount],
					' + CAST(@CleanOrphan AS NVARCHAR(8))		+ ' AS [CleanOrphan],
					' + CAST(@CleanInternal AS NVARCHAR(8))		+ ' AS [CleanInternal]
				FOR XML PATH (''CleanupParameters''), ROOT(''Root'')
			) AS [CleanupParameters]
		FROM #QueryDetailsTable [qdt]
		ORDER BY
			[qdt].[QueryType] ASC,
			[qdt].[QueryID] ASC'
		IF (@Debug = 1) PRINT (@QueryDetailsOutputInsert)
		EXECUTE (@QueryDetailsOutputInsert)
	END
	-- Detailed Report: Persisted-table output - END
END



-- Perform actual cleanup operations - START
DECLARE @DeleteableQueryID BIGINT
DECLARE @DeleteablePlanID BIGINT

DECLARE @DeleteableQueryDeletedTable TABLE (query_id BIGINT, plan_id BIGINT, PRIMARY KEY (query_id ASC, plan_id))
DECLARE @UnforcePlanCmd VARCHAR(MAX)
DECLARE @RemoveQueryCmd VARCHAR(MAX)
WHILE (SELECT COUNT(1) FROM #DeleteableQueryTable) > 0
-- Loop through each query in the list, starting with the ones having a forced plan on then (plan_id <> 0) - START
BEGIN
	;WITH dqt AS ( SELECT TOP(1) * FROM #DeleteableQueryTable ORDER BY plan_id DESC)
	DELETE FROM dqt
	OUTPUT DELETED.query_id, DELETED.plan_id INTO @DeleteableQueryDeletedTable
	SELECT TOP(1) @DeleteableQueryID = query_id, @DeleteablePlanID = plan_id FROM @DeleteableQueryDeletedTable
	DELETE FROM @DeleteableQueryDeletedTable

	-- If there is a forced plan for the query, unforce it before removing the query (queries with forced plans cna't be removed) - START
	IF (@DeleteablePlanID <> 0)
	BEGIN
		-- Unforce the plan (if any) - START
		IF (@Verbose = 1) PRINT 'Unforce plan : ' + CAST(@DeleteablePlanID AS VARCHAR(19)) + ' for query :' + CAST(@DeleteableQueryID AS VARCHAR(19))
		SET @UnforcePlanCmd = @DatabaseName+'..sp_query_store_unforce_plan @query_id = ' + CAST(@DeleteableQueryID AS VARCHAR(19))+ ', @plan_id = '+ CAST(@DeleteablePlanID AS VARCHAR(19))+';'
		IF (@Debug = 1) PRINT (@UnforcePlanCmd)
		IF (@Test = 0) EXECUTE (@UnforcePlanCmd)
		-- Unforce the plan (if any) - END
	END
	-- If there is a forced plan for the query, unforce it before removing the query (queries with forced plans can't be removed) - END

	-- Delete the query from Query Store - START
	IF (@Verbose = 1) PRINT 'Remove query : ' + CAST(@DeleteableQueryID AS VARCHAR(19))
	SET @RemoveQueryCmd = @DatabaseName+'..sp_query_store_remove_query @query_id = ' + CAST(@DeleteableQueryID AS VARCHAR(19))+';'
	IF (@Debug = 1) PRINT (@RemoveQueryCmd)
	IF (@Test = 0) EXECUTE (@RemoveQueryCmd) 
	-- Delete the query from Query Store - END

	-- Delete the query from #DeleteableQueryTable to prevent the loop from trying to remove the same query multiple times - START
	DELETE FROM #DeleteableQueryTable WHERE query_id = @DeleteableQueryID
	-- Delete the query from #DeleteableQueryTable to prevent the loop from trying to remove the same query multiple times - END
END
-- Loop through each query in the list, starting with the ones having a forced plan on then (plan_id <> 0) - END

DROP TABLE IF EXISTS #DeleteableQueryTable
-- Perform actual cleanup operations - START

END